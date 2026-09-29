# API-Level MCP Server Recipe

## Purpose

Add a Model Context Protocol (MCP) endpoint to a cloud-hosted API so AI agents
can access user data without the desktop app running. This recipe handles
multi-tenant isolation (multiple users with separate data), agent key
authentication with bcrypt, database-backed sessions for horizontal scaling, and
permission enforcement on every tool call.

The core value is in the integration glue: how the MCP TypeScript SDK connects
to a Bun/Elysia server, how agent keys are validated efficiently with prefix
prefiltering, how sessions cache resolved permissions, and how the two-layer
auth model (OAuth for user identity + agent keys for permissions) works
together.

## UI Reference

See `references/mcp-management-mockup.html` for an interactive prototype of the
MCP management interface. Open in a browser — no build step required.

The prototype covers 13 states across 4 tabs:

- **Access Groups** — list, new group, edit group, delete confirm, folder picker
- **Agents** — list, new agent
- **Roles** — list, new role (with permission category checkboxes)
- **Keys** — list, issue key (agent + group + role selection), key generated
  (one-time display), delete confirm

Use this as the visual starting point for any management UI built around this
recipe. The folder picker pattern (hierarchical project/folder tree with
indeterminate checkbox states) is worth reviewing before implementing that flow.

## When to Use

- You have a cloud-hosted API with user data you want AI agents to access
- Multiple users need isolated MCP access to their own data
- You need agent key authentication with role-based permissions
- You want agents to work without the desktop app running
- Your API already has an auth system (Better Auth, NextAuth, Lucia, etc.)

## Technology Stack

| Layer       | Technology                   | Version |
| ----------- | ---------------------------- | ------- |
| Runtime     | Bun                          | 1.2+    |
| Framework   | Elysia                       | 1.4+    |
| MCP SDK     | @modelcontextprotocol/sdk    | 1.26+   |
| ORM         | Drizzle ORM with postgres.js | 0.45+   |
| Database    | PostgreSQL                   | 15+     |
| Key Hashing | bcryptjs                     | 2.4+    |
| Validation  | Zod 4                        | 4.x     |

**Prerequisite Recipes:**

- [Elysia + BetterAuth API](../elysia-betterauth-api/RECIPE.md) — Base API
  server setup
- [BetterAuth OAuth Provider](../elysia-betterauth-oauth/RECIPE.md) — OAuth 2.1
  for transport-level authentication (required for production multi-tenant
  deployments)

## Architecture Overview

```
MCP Client (Claude Code, Cursor, etc.)
    │
    │  HTTP + Bearer token (OAuth access_token)
    ▼
┌─────────────────────────────────────────────────┐
│  Elysia Route Handler (/api/mcp)                │
│  ├─ POST — Client-to-server MCP messages        │
│  ├─ GET  — Server-to-client SSE stream          │
│  └─ DELETE — Session termination                │
│                                                 │
│  1. OAuth middleware resolves user identity      │
│  2. 401 + WWW-Authenticate if unauthenticated   │
│  3. Create per-request MCP server + transport    │
│  4. Delegate to MCP SDK                         │
└──────────────────┬──────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────┐
│  MCP Server (stateless, per-request)            │
│                                                 │
│  Tool: authenticate                             │
│  ├─ Validates agent key (bcrypt + prefix)       │
│  ├─ Cross-validates: key owner == OAuth user    │
│  └─ Creates database session with permissions   │
│                                                 │
│  Tool: your_tool_name                           │
│  ├─ Validates session (not expired)             │
│  ├─ Enforces permission (role check)            │
│  ├─ Enforces resource access (folder check)     │
│  └─ Calls service layer with ownerId filter     │
└──────────────────┬──────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────┐
│  Service Layer                                  │
│  Every method takes ownerId as parameter        │
│  Every query includes ownerId WHERE clause      │
└──────────────────┬──────────────────────────────┘
                   │
                   ▼
              PostgreSQL
```

### Key Design Decisions

**Two-layer authentication.** OAuth establishes user identity at the transport
level (which human user is making the request). Agent keys establish permissions
at the application level (which agent, with what role, accessing which folders).
This separation means the MCP endpoint uses the same OAuth infrastructure as the
rest of your API, while agent-specific permissions live in their own system.

**Stateless server instances.** A new MCP server is created for every HTTP
request. No in-memory state, no connection lifecycle management, no cleanup.
Sessions live in PostgreSQL. This is simpler and scales horizontally.

**Database-backed sessions.** Sessions cache resolved permissions (which tools
the agent can use, which folders it can access) so each tool call doesn't need
to re-resolve the full agent → membership → role → access group → folder chain.
Sessions expire after 24 hours.

**Prefix prefiltering for bcrypt.** bcrypt with 12 rounds takes ~250ms per
comparison. Without prefiltering, validating one key against 100 memberships =
25 seconds. Storing the first 8 characters of each key as a `key_prefix` column
lets you filter candidates with a fast SQL query before running bcrypt. This
reduces bcrypt calls from O(n) to O(1-2).

**ownerId on everything.** Every table has an `owner_id` column. Every service
method takes `ownerId` as a parameter. Every query includes it in the WHERE
clause. This is the multi-tenant isolation boundary — miss one and you leak data
between users.

## Data Model

Six tables for the MCP auth system. All tables have `owner_id` for multi-tenant
isolation.

```
┌──────────────┐     ┌──────────────────────┐     ┌─────────────┐
│  mcp_agents  │     │  mcp_agent_group_    │     │  mcp_roles  │
│              │────▶│  membership          │◀────│             │
│  id          │     │                      │     │  id         │
│  name        │     │  id                  │     │  name       │
│  description │     │  agent_id       (FK) │     │  permissions│ ← JSON array
│  owner_id    │     │  access_group_id(FK) │     │  owner_id   │
└──────────────┘     │  role_id        (FK) │     └─────────────┘
                     │  key_hash            │
                     │  key_prefix          │ ← first 8 chars
                     │  revoked_at          │ ← soft revocation
                     │  owner_id            │
                     └──────────┬───────────┘
                                │
                     ┌──────────▼───────────┐     ┌────────────────────────┐
                     │  mcp_access_groups   │     │  mcp_group_folder_     │
                     │                      │────▶│  access                │
                     │  id                  │     │                        │
                     │  name                │     │  access_group_id  (FK) │
                     │  description         │     │  group_id         (FK) │ ← your folder table
                     │  owner_id            │     │  owner_id              │
                     └──────────────────────┘     └────────────────────────┘

                     ┌──────────────────────┐
                     │  mcp_sessions        │
                     │                      │ ← caches resolved permissions
                     │  id                  │
                     │  agent_id            │
                     │  membership_id       │
                     │  access_group_id     │
                     │  allowed_group_ids   │ ← jsonb array of folder IDs
                     │  permissions         │ ← jsonb array of tool names
                     │  owner_id            │
                     │  expires_at          │ ← 24 hours
                     └──────────────────────┘
```

### Key Schema Details

```typescript
import {
  pgTable,
  text,
  timestamp,
  index,
  uniqueIndex,
  jsonb,
} from "drizzle-orm/pg-core";

// Agent identities
export const mcpAgents = pgTable(
  "mcp_agents",
  {
    id: text("id").primaryKey(),
    name: text("name").notNull(),
    description: text("description"),
    ownerId: text("owner_id").notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull(),
  },
  (table) => [index("idx_mcp_agents_owner").on(table.ownerId)]
);

// Agent credentials — links agents to access groups with roles
export const mcpAgentGroupMembership = pgTable(
  "mcp_agent_group_membership",
  {
    id: text("id").primaryKey(),
    agentId: text("agent_id").notNull(),
    accessGroupId: text("access_group_id").notNull(),
    roleId: text("role_id").notNull(),
    keyHash: text("key_hash").notNull(), // bcrypt hash
    keyPrefix: text("key_prefix").notNull(), // first 8 chars for prefiltering
    key: text("key").notNull().default(""), // full key (shown to user once)
    ownerId: text("owner_id").notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
    revokedAt: timestamp("revoked_at", { withTimezone: true }), // soft revoke
    lastUsedAt: timestamp("last_used_at", { withTimezone: true }),
  },
  (table) => [
    uniqueIndex("idx_mcp_membership_key_hash").on(table.keyHash),
    index("idx_mcp_membership_owner").on(table.ownerId),
    uniqueIndex("idx_mcp_membership_unique").on(
      table.agentId,
      table.accessGroupId
    ),
  ]
);

// Roles — named permission sets
export const mcpRoles = pgTable("mcp_roles", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  description: text("description"),
  permissions: text("permissions").notNull(), // JSON array: ["browse", "read_document", ...]
  ownerId: text("owner_id").notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull(),
});

// Sessions — database-backed, caches resolved permissions
export const mcpSessions = pgTable(
  "mcp_sessions",
  {
    id: text("id").primaryKey(),
    agentId: text("agent_id").notNull(),
    membershipId: text("membership_id").notNull(),
    accessGroupId: text("access_group_id").notNull(),
    allowedGroupIds: jsonb("allowed_group_ids").notNull().$type<string[]>(),
    permissions: jsonb("permissions").notNull().$type<string[]>(),
    ownerId: text("owner_id").notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
    expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  },
  (table) => [index("idx_mcp_sessions_expires").on(table.expiresAt)]
);
```

**Key constraints:**

- `key_hash` has a UNIQUE index — prevents key reuse across memberships
- `(agent_id, access_group_id)` has a UNIQUE index — one membership per
  agent-group pair
- `permissions` uses `jsonb` — no schema migration needed when adding tools
- `revoked_at` enables soft revocation with an audit trail

## Service Layer

### Permission Constants

Define a central registry of permission names that map 1:1 with tool names. This
registry is used for role definitions, session caching, and enforcement.

```typescript
// permissions/constants.ts
export const MCP_PERMISSIONS = {
  // Define your tool permissions here
  // Example read permissions:
  browse: "browse",
  search: "search",
  read_item: "read_item",
  // Example write permissions:
  create_item: "create_item",
  update_item: "update_item",
  delete_item: "delete_item",
} as const;

export type McpPermission =
  (typeof MCP_PERMISSIONS)[keyof typeof MCP_PERMISSIONS];

export const ALL_PERMISSIONS = Object.values(MCP_PERMISSIONS);
```

### Permission Enforcement

```typescript
// permissions.ts
export function enforcePermission(
  session: { permissions: string[] },
  permission: string,
  toolName: string
): void {
  const perms = session.permissions as string[];
  if (!perms.includes(permission)) {
    throw new Error(
      `Permission denied: tool "${toolName}" requires "${permission}" permission. ` +
        `Your permissions are: ${perms.join(", ")}`
    );
  }
}
```

### Subtree Folder Access Check

If an agent has access to folder "Projects", it implicitly has access to
"Projects/Work/Q1". The check walks up the parent chain from the target folder
to see if any ancestor is in the allowed list.

```typescript
// permissions.ts
export async function isGroupOrAncestorAllowed(
  groupId: string,
  allowedGroupIds: string[],
  ownerId: string
): Promise<boolean> {
  const allowedSet = new Set(allowedGroupIds);
  const visited = new Set<string>(); // Circular reference guard
  let currentGroupId: string | null = groupId;

  while (currentGroupId) {
    if (visited.has(currentGroupId)) return false;
    visited.add(currentGroupId);

    if (allowedSet.has(currentGroupId)) return true;

    // Walk up to parent — your service provides this
    currentGroupId = await getParentGroupId(currentGroupId, ownerId);
  }

  return false;
}
```

### Agent Key Validation (Critical Path)

The 3-stage validation flow with prefix prefiltering:

```typescript
// services/membership.service.ts
import bcrypt from "bcryptjs";

export const membershipService = {
  async validateAgentKey(agentKey: string) {
    // Stage 1: Basic validation
    if (!agentKey || typeof agentKey !== "string" || agentKey.length < 10) {
      return null;
    }

    // Stage 2: Prefix prefiltering (CRITICAL for performance)
    const prefix = agentKey.substring(0, 8);
    const candidates = await db
      .select()
      .from(mcpAgentGroupMembership)
      .where(
        and(
          eq(mcpAgentGroupMembership.keyPrefix, prefix),
          isNull(mcpAgentGroupMembership.revokedAt) // Exclude revoked
        )
      );

    // Stage 3: bcrypt compare — slow but secure, only 1-2 candidates
    let membership = null;
    for (const candidate of candidates) {
      if (await bcrypt.compare(agentKey, candidate.keyHash)) {
        membership = candidate;
        break;
      }
    }
    if (!membership) return null;

    // Load related entities (agent, access group, role, folder access)
    const [agent] = await db
      .select()
      .from(mcpAgents)
      .where(eq(mcpAgents.id, membership.agentId))
      .limit(1);
    if (!agent) return null;

    const [accessGroup] = await db
      .select()
      .from(mcpAccessGroups)
      .where(eq(mcpAccessGroups.id, membership.accessGroupId))
      .limit(1);
    if (!accessGroup) return null;

    const [role] = await db
      .select()
      .from(mcpRoles)
      .where(eq(mcpRoles.id, membership.roleId))
      .limit(1);
    if (!role) return null;

    const permissions = JSON.parse(role.permissions) as string[];

    const folderAccess = await db
      .select({ groupId: mcpGroupFolderAccess.groupId })
      .from(mcpGroupFolderAccess)
      .where(eq(mcpGroupFolderAccess.accessGroupId, accessGroup.id));
    const allowedFolderIds = folderAccess.map((fa) => fa.groupId);

    return {
      membership,
      agent,
      accessGroup,
      role,
      allowedFolderIds,
      permissions,
      ownerId: membership.ownerId,
    };
  },

  async updateLastUsed(membershipId: string): Promise<void> {
    await db
      .update(mcpAgentGroupMembership)
      .set({ lastUsedAt: new Date() })
      .where(eq(mcpAgentGroupMembership.id, membershipId));
  },
};
```

### Session Service

```typescript
// services/session.service.ts
const SESSION_TTL_HOURS = 24;
const HOUR_IN_MS = 60 * 60 * 1000;

export const sessionService = {
  async createSession(
    agentId: string,
    membershipId: string,
    accessGroupId: string,
    allowedGroupIds: string[],
    permissions: string[],
    ownerId: string
  ): Promise<{ sessionId: string; expiresAt: Date }> {
    const sessionId = crypto.randomUUID(); // or nanoid()
    const now = new Date();
    const expiresAt = new Date(now.getTime() + SESSION_TTL_HOURS * HOUR_IN_MS);

    await db.insert(mcpSessions).values({
      id: sessionId,
      agentId,
      membershipId,
      accessGroupId,
      allowedGroupIds,
      permissions,
      ownerId,
      createdAt: now,
      expiresAt,
    });

    return { sessionId, expiresAt };
  },

  async getSession(sessionId: string) {
    const [session] = await db
      .select()
      .from(mcpSessions)
      .where(eq(mcpSessions.id, sessionId))
      .limit(1);

    if (!session) return null;
    if (new Date() > session.expiresAt) {
      await db.delete(mcpSessions).where(eq(mcpSessions.id, sessionId));
      return null;
    }

    return session;
  },

  async deleteSession(sessionId: string): Promise<void> {
    await db.delete(mcpSessions).where(eq(mcpSessions.id, sessionId));
  },

  async cleanupExpiredSessions(): Promise<number> {
    const result = await db
      .delete(mcpSessions)
      .where(lt(mcpSessions.expiresAt, new Date()))
      .returning({ id: mcpSessions.id });
    return result.length;
  },
};
```

## Implementation Process

### Phase 1: Install Dependencies and Schema

**1.1 Install the MCP SDK and bcrypt**

```bash
bun add @modelcontextprotocol/sdk bcryptjs zod
bun add -d @types/bcryptjs
```

**IMPORTANT — Zod version:** MCP SDK 1.26+ requires Zod 4. If your project is on
Zod 3, upgrade to Zod 4 first. They are different packages and Zod 4 is a
monorepo-wide change — budget time for it.

**1.2 Create directory structure**

```bash
mkdir -p src/features/mcp/services
mkdir -p src/routes/mcp
```

**1.3 Create the database schema**

Create `src/features/mcp/db.ts` with the six tables from the Data Model section.
Adapt the table and column names to your project conventions, but preserve:

- `owner_id` on every table
- `key_hash` + `key_prefix` on the membership table
- `jsonb` for `allowed_group_ids` and `permissions` on sessions
- `revoked_at` for soft revocation on memberships

Add the schema file to your `drizzle.config.ts` and run the migration:

```bash
bun run db:generate
bun run db:migrate
```

**Validate:**

- [ ] Migration runs successfully
- [ ] All six tables exist with `owner_id` columns
- [ ] `key_hash` has a unique constraint

### Phase 2: Transport Adapter (If Needed)

**Skip this phase if:** Your MCP SDK version includes
`WebStandardStreamableHTTPServerTransport` (SDK 1.30+). This transport works
natively with Fetch API `Request`/`Response` and requires no adapter.

**You need an adapter if:** Your SDK version only has
`StreamableHTTPServerTransport` (which expects Node.js `IncomingMessage` /
`ServerResponse`).

**The Problem:** The MCP SDK historically expected Node.js HTTP primitives. Bun,
Deno, Cloudflare Workers, and similar runtimes use Web Standard
`Request`/`Response`. Passing a `Request` where the SDK expects
`IncomingMessage` crashes on `.on()`, `.pipe()`, `.writeHead()`, etc.

**The Adapter Pattern:**

Create `src/features/mcp/adapter.ts`:

```typescript
import { IncomingMessage, ServerResponse } from "node:http";
import { Socket } from "node:net";

/**
 * Convert Web Standard Request to Node.js IncomingMessage + ServerResponse
 * for use with StreamableHTTPServerTransport.
 */
export function toReqRes(request: Request): {
  req: IncomingMessage;
  res: MockServerResponse;
} {
  const socket = new Socket();
  const req = new IncomingMessage(socket);
  req.method = request.method;
  req.url = new URL(request.url).pathname;

  const headers: Record<string, string> = {};
  request.headers.forEach((value, key) => {
    headers[key.toLowerCase()] = value;
  });
  req.headers = headers;

  const res = new MockServerResponse(req);
  return { req, res };
}

/**
 * Convert captured MockServerResponse back to Web Standard Response.
 */
export function toFetchResponse(res: MockServerResponse): Response {
  const headers = new Headers();
  const rawHeaders = res.getHeaders();
  for (const [key, value] of Object.entries(rawHeaders)) {
    if (value !== undefined) {
      if (Array.isArray(value)) {
        for (const v of value) headers.append(key, v);
      } else {
        headers.set(key, String(value));
      }
    }
  }

  const body = res.getBody();
  const contentType = headers.get("content-type") || "";

  // Handle SSE streams
  if (contentType.includes("text/event-stream")) {
    const stream = new ReadableStream({
      start(controller) {
        if (body.length > 0) {
          controller.enqueue(new TextEncoder().encode(body));
        }
        controller.close();
      },
    });
    return new Response(stream, { status: res.statusCode, headers });
  }

  return new Response(body || null, { status: res.statusCode, headers });
}

/**
 * ServerResponse subclass that captures written data.
 */
export class MockServerResponse extends ServerResponse {
  private _chunks: Buffer[] = [];
  private _ended = false;

  constructor(req: IncomingMessage) {
    super(req);
    this.assignSocket(
      new CaptureSocket(this._chunks, () => {
        this._ended = true;
      })
    );
  }

  getBody(): string {
    return Buffer.concat(this._chunks).toString("utf-8");
  }

  hasEnded(): boolean {
    return this._ended;
  }
}

/**
 * Socket subclass that captures writes instead of sending over TCP.
 */
class CaptureSocket extends Socket {
  constructor(
    private chunks: Buffer[],
    private onEnd: () => void
  ) {
    super();
    Object.defineProperty(this, "writable", { value: true, writable: true });
  }

  override write(
    data: Uint8Array | string,
    encodingOrCb?: BufferEncoding | ((err?: Error) => void),
    cb?: (err?: Error) => void
  ): boolean {
    const encoding = typeof encodingOrCb === "string" ? encodingOrCb : "utf-8";
    const callback = typeof encodingOrCb === "function" ? encodingOrCb : cb;
    if (typeof data === "string") {
      this.chunks.push(Buffer.from(data, encoding));
    } else {
      this.chunks.push(Buffer.from(data));
    }
    if (callback) callback();
    return true;
  }

  override end(
    data?: unknown,
    encodingOrCb?: BufferEncoding | (() => void),
    cb?: () => void
  ): this {
    if (data) {
      if (typeof data === "string") {
        const encoding =
          typeof encodingOrCb === "string" ? encodingOrCb : "utf-8";
        this.chunks.push(Buffer.from(data, encoding));
      } else if (Buffer.isBuffer(data) || data instanceof Uint8Array) {
        this.chunks.push(Buffer.from(data));
      }
    }
    this.onEnd();
    const callback = typeof encodingOrCb === "function" ? encodingOrCb : cb;
    if (callback) callback();
    return this;
  }

  override destroy(): this {
    return this;
  }
}
```

**When to use which approach:**

| SDK Version | Transport Class                            | Adapter Needed? |
| ----------- | ------------------------------------------ | --------------- |
| < 1.30      | `StreamableHTTPServerTransport`            | Yes             |
| >= 1.30     | `WebStandardStreamableHTTPServerTransport` | No              |

**Validate:**

- [ ] POST to `/api/mcp` with `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`
      returns a tool list (after auth is set up)

### Phase 3: MCP Server Factory and Route Handler

**3.1 Server factory** (`src/features/mcp/server.ts`)

Create a new MCP server per request. Pass the OAuth user ID for
cross-validation.

```typescript
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerTools } from "./tools";

export function createMCPServer(oauthUserId: string): McpServer {
  const server = new McpServer(
    { name: "your-app-api", version: "1.0.0" },
    { capabilities: { tools: {} } }
  );

  registerTools(server, oauthUserId);
  return server;
}
```

**3.2 Route handler** (`src/routes/mcp/index.ts`)

The route handler creates a per-request server + transport, delegates to the MCP
SDK, and returns the response.

**With WebStandardStreamableHTTPServerTransport (SDK 1.30+):**

```typescript
import { Elysia } from "elysia";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { createMCPServer } from "@features/mcp/server";
import { sessionMiddleware } from "@core/http";
import { env } from "@core/config";
import type { User } from "@features/auth";

const RESOURCE_METADATA_URL = `${env.BETTER_AUTH_URL}/.well-known/oauth-protected-resource`;

function unauthorizedResponse(): Response {
  return new Response(
    JSON.stringify({
      jsonrpc: "2.0",
      error: { code: -32001, message: "Authentication required" },
    }),
    {
      status: 401,
      headers: {
        "content-type": "application/json",
        "www-authenticate": `Bearer resource_metadata="${RESOURCE_METADATA_URL}"`,
      },
    }
  );
}

export const mcpRoutes = new Elysia({ prefix: "/api/mcp" })
  .use(sessionMiddleware)
  .post(
    "",
    async ({ request, user }) => {
      if (!user) return unauthorizedResponse();
      return handleMcpRequest(request, user);
    },
    // parse: "none" keeps Elysia from draining the request body before the MCP
    // SDK reads it. Without this, authenticated POSTs return a silent
    // `-32700 Parse error: Invalid JSON` with a 200 status.
    { parse: "none" }
  )
  .get("", async ({ request, user }) => {
    if (!user) return unauthorizedResponse();
    return handleMcpRequest(request, user);
  })
  .delete("", async ({ request, user }) => {
    if (!user) return unauthorizedResponse();
    return handleMcpRequest(request, user);
  });

async function handleMcpRequest(
  request: Request,
  user: User
): Promise<Response> {
  try {
    const server = createMCPServer(user.id);

    const transport = new WebStandardStreamableHTTPServerTransport({
      sessionIdGenerator: undefined, // Stateless mode
    });

    await server.connect(transport);
    const response = await transport.handleRequest(request);

    // Clean up non-streaming responses
    const contentType = response.headers.get("content-type") || "";
    if (!contentType.includes("text/event-stream")) {
      await transport.close();
      await server.close();
    }

    return response;
  } catch (err) {
    console.error("[mcp] handleMcpRequest error:", err);
    return new Response(
      JSON.stringify({
        jsonrpc: "2.0",
        error: { code: -32603, message: "Internal server error" },
      }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }
}
```

**With the Node.js adapter (SDK < 1.30):**

Replace `WebStandardStreamableHTTPServerTransport` with
`StreamableHTTPServerTransport` and use the adapter:

```typescript
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { toReqRes, toFetchResponse } from "@features/mcp/adapter";

async function handleMcpRequest(request: Request, user: User) {
  const server = createMCPServer(user.id);
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
  });
  await server.connect(transport);

  const { req, res } = toReqRes(request);
  await transport.handleRequest(req, res);
  return toFetchResponse(res);
}
```

**Validate:**

- [ ] POST to `/api/mcp` without auth returns 401 with `WWW-Authenticate` header
- [ ] GET to `/api/mcp` doesn't crash (SSE endpoint)
- [ ] DELETE to `/api/mcp` doesn't crash (session termination)

### Phase 4: Tool Registration

Tools are where your application logic lives. The recipe provides the
**authenticate** tool (required) and the **tool registration pattern** that you
adapt for your domain.

**4.1 Session validation helper**

Every tool except `authenticate` needs this:

```typescript
// tools.ts
async function getValidatedSession(sessionId: string, oauthUserId: string) {
  const session = await sessionService.getSession(sessionId);
  if (!session) {
    throw new Error("Session expired or invalid. Please re-authenticate.");
  }
  // Cross-validate: session owner must match OAuth user
  if (session.ownerId !== oauthUserId) {
    throw new Error("Session does not belong to the authenticated user.");
  }
  return session;
}
```

**4.2 The authenticate tool (required)**

This tool exchanges an agent key for a session ID:

```typescript
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

export function registerTools(server: McpServer, oauthUserId: string): void {
  // Always register authenticate first
  server.tool(
    "authenticate",
    "Authenticate with an agent key to get a session ID. " +
      "Must be called before any other tool.",
    { agentKey: z.string() },
    async ({ agentKey }) => {
      const result = await membershipService.validateAgentKey(agentKey);
      if (!result) throw new Error("Invalid or revoked agent key");

      // Cross-validate: key owner must match OAuth user
      if (result.ownerId !== oauthUserId) {
        throw new Error("Agent key does not belong to the authenticated user");
      }

      const { sessionId, expiresAt } = await sessionService.createSession(
        result.agent.id,
        result.membership.id,
        result.accessGroup.id,
        result.allowedFolderIds,
        result.permissions,
        result.ownerId
      );

      await membershipService.updateLastUsed(result.membership.id);

      // Tell the agent what it can and cannot do
      const deniedTools = ALL_PERMISSIONS.filter(
        (p) => !result.permissions.includes(p)
      );

      let instructions = "Use sessionId in all subsequent tool calls. ";
      instructions += `Your permissions: ${result.permissions.join(", ")}. `;
      if (deniedTools.length > 0) {
        instructions += `NOT available: ${deniedTools.join(", ")}.`;
      }

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              {
                sessionId,
                expiresAt: expiresAt.toISOString(),
                accessGroup: {
                  id: result.accessGroup.id,
                  name: result.accessGroup.name,
                },
                role: result.role
                  ? { id: result.role.id, name: result.role.name }
                  : null,
                permissions: result.permissions,
                instructions,
              },
              null,
              2
            ),
          },
        ],
      };
    }
  );

  // Register your domain-specific tools below
  // registerYourReadTool(server, oauthUserId);
  // registerYourWriteTool(server, oauthUserId);
}
```

**4.3 Read tool pattern**

Every read tool follows this structure:

```typescript
server.tool(
  "your_read_tool",
  "Description of what this tool reads. Requires your_read_tool permission.",
  {
    sessionId: z.string(),
    // ... your tool-specific parameters
  },
  async ({ sessionId, ...params }) => {
    // 1. Validate session + cross-check OAuth user
    const session = await getValidatedSession(sessionId, oauthUserId);

    // 2. Enforce permission
    enforcePermission(session, "your_read_tool", "your_read_tool");

    // 3. Check resource access (if applicable)
    const allowedGroupIds = session.allowedGroupIds as string[];
    const isAllowed = await isGroupOrAncestorAllowed(
      targetGroupId,
      allowedGroupIds,
      session.ownerId
    );
    if (!isAllowed) throw new Error("Resource not accessible");

    // 4. Call service layer with ownerId
    const data = await yourService.get(params.id, session.ownerId);

    // 5. Return JSON result
    return {
      content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
    };
  }
);
```

**4.4 Write tool pattern**

Write tools add resource existence validation and may include domain-specific
logic:

```typescript
server.tool(
  "your_write_tool",
  "Description. Requires your_write_tool permission and folder access.",
  {
    sessionId: z.string(),
    targetGroupId: z.string(),
    // ... your write-specific parameters
  },
  async ({ sessionId, targetGroupId, ...params }) => {
    // 1. Validate session + cross-check OAuth user
    const session = await getValidatedSession(sessionId, oauthUserId);

    // 2. Enforce permission
    enforcePermission(session, "your_write_tool", "your_write_tool");

    // 3. Validate target resource exists
    const group = await groupService.get(targetGroupId, session.ownerId);
    if (!group) throw new Error(`Folder ${targetGroupId} not found`);

    // 4. Check folder access (subtree model)
    const allowedGroupIds = session.allowedGroupIds as string[];
    const isAllowed = await isGroupOrAncestorAllowed(
      targetGroupId,
      allowedGroupIds,
      session.ownerId
    );
    if (!isAllowed) {
      throw new Error(`Folder ${targetGroupId} is not accessible`);
    }

    // 5. Perform the write via service layer
    const result = await yourService.create(
      params,
      session.ownerId,
      `ai:agent:${session.agentId}` // Track who created it
    );

    // 6. Return result
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({ id: result.id, ...result }, null, 2),
        },
      ],
    };
  }
);
```

**Validate:**

- [ ] `authenticate` returns session with permissions
- [ ] Tools reject expired/invalid session IDs
- [ ] Tools reject calls without required permissions
- [ ] Subtree folder access works (parent access grants child access)
- [ ] Cross-user validation prevents User A from using User B's agent key

### Phase 5: OAuth Discovery Endpoints (MCP-Specific)

MCP clients (Claude Code, Cursor) discover how to authenticate by following the
OAuth Protected Resource Metadata standard (RFC 9728). This is the intersection
where MCP relies on OAuth — these endpoints are what make automatic OAuth
discovery work.

**5.1 Protected Resource Metadata** (RFC 9728)

This tells MCP clients where to find the authorization server. Register the
document at **both** the root well-known URL and a path-scoped variant that
mirrors the MCP resource path — Claude Code honors the
`WWW-Authenticate: Bearer resource_metadata=<url>` hint and fetches only the URL
from the header, but Claude Desktop ignores the hint and constructs its own URL
by appending the resource path to `/.well-known/oauth-protected-resource`.
Without the path-scoped variant, Desktop discovery fails silently.

```typescript
// src/routes/mcp/resource-metadata.ts
import { Elysia } from "elysia";
import { env } from "@core/config";

const metadata = () => ({
  resource: `${env.BETTER_AUTH_URL}/api/mcp`,
  authorization_servers: [env.BETTER_AUTH_URL],
  bearer_methods_supported: ["header"],
  scopes_supported: ["openid", "profile", "email", "offline_access"],
});

export const resourceMetadataRoute = new Elysia()
  // Root form — used by Claude Code via WWW-Authenticate hint.
  .get("/.well-known/oauth-protected-resource", metadata)
  // Path-scoped form — used by Claude Desktop, which probes
  // /.well-known/oauth-protected-resource/<mcp-resource-path> directly.
  .get("/.well-known/oauth-protected-resource/api/mcp", metadata);
```

**5.2 Authorization Server Metadata** (RFC 8414)

If you're using BetterAuth with the OAuth Provider plugin, it provides a helper
to generate this metadata:

```typescript
// src/routes/mcp/auth-server-metadata.ts
import { Elysia } from "elysia";
import { oauthProviderAuthServerMetadata } from "@better-auth/oauth-provider";
import { auth } from "@features/auth";

const handler = oauthProviderAuthServerMetadata(auth);

export const authServerMetadataRoute = new Elysia()
  .get("/.well-known/oauth-authorization-server", async ({ request }) =>
    handler(request)
  )
  // Path-scoped form for Claude Desktop.
  .get("/.well-known/oauth-authorization-server/api/mcp", async ({ request }) =>
    handler(request)
  );
```

**IMPORTANT:** These well-known endpoints live at the domain root (per RFC 8615)
**and** at a path-scoped form that mirrors the MCP resource. Both sets must be
registered on the app root, not under `/api/mcp`:

```typescript
// src/index.ts
import { resourceMetadataRoute } from "./routes/mcp/resource-metadata";
import { authServerMetadataRoute } from "./routes/mcp/auth-server-metadata";
import { mcpRoutes } from "./routes/mcp";

const app = new Elysia()
  // ... cors, session middleware, auth handler ...
  .use(resourceMetadataRoute) // /.well-known/oauth-protected-resource
  .use(authServerMetadataRoute) // /.well-known/oauth-authorization-server
  .use(mcpRoutes) // /api/mcp
  .listen({ hostname: "0.0.0.0", port: env.BUN_PORT });
```

**How the discovery flow works:**

1. MCP client POSTs to `/api/mcp` — gets 401 with
   `WWW-Authenticate: Bearer resource_metadata="..."`
2. Client fetches `/.well-known/oauth-protected-resource` — learns the
   authorization server URL
3. Client fetches `/.well-known/oauth-authorization-server` — learns the
   authorize, token, and registration endpoints
4. Client performs OAuth PKCE flow in a browser
5. Client retries the POST with `Authorization: Bearer {access_token}`
6. Server resolves the user from the bearer token and handles the MCP request

If your auth system isn't BetterAuth, you need to serve equivalent metadata
documents from your authorization server. The specific endpoints
(`authorization_endpoint`, `token_endpoint`, etc.) depend on your OAuth
provider.

**Validate:**

- [ ] `GET /.well-known/oauth-protected-resource` returns valid JSON with
      `authorization_servers`
- [ ] `GET /.well-known/oauth-protected-resource/api/mcp` returns the same body
      (path-scoped form for Claude Desktop)
- [ ] `GET /.well-known/oauth-authorization-server` returns valid OAuth metadata
- [ ] `GET /.well-known/oauth-authorization-server/api/mcp` returns the same
      body (path-scoped form for Claude Desktop)
- [ ] Unauthenticated POST to `/api/mcp` returns 401 with `WWW-Authenticate`
      header containing the resource metadata URL

**5.3 Claude Desktop DCR compatibility (required if you support Desktop)**

Claude Code, MCP Inspector, and most CLI clients work with the discovery
endpoints above. Claude Desktop's "custom connector" has one additional
requirement that is not documented upstream and fails silently if unmet: its
Dynamic Client Registration request is a confidential-client shape, sent without
authentication.

The exact request Desktop's backend sends to `/api/auth/oauth2/register`:

```json
{
  "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
  "token_endpoint_auth_method": "client_secret_post",
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "scope": "openid profile email offline_access",
  "client_name": "Claude"
}
```

`@better-auth/oauth-provider` hardcodes a 401 for confidential DCR without a
session (`Authentication required for confidential client registration`), with
no config flag to relax it. Claude.ai's backend aborts silently on any non-2xx
DCR response, so the only user-visible symptom is "Couldn't reach the MCP
server" with an opaque `ofid_<hex>` reference.

**The fix:** register a route for `POST /api/auth/oauth2/register` **before**
the mounted OAuth handler that coerces confidential auth methods to `none`
before forwarding:

```typescript
// src/routes/mcp/dcr-intercept.ts
import { Elysia } from "elysia";
import { auth } from "@features/auth";

export function coerceConfidentialDcrToPublic(body: string): string {
  if (!body) return body;
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return body;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return body;
  }
  const obj = parsed as { token_endpoint_auth_method?: string };
  const method = obj.token_endpoint_auth_method;
  if (!method || method === "none") return body;
  return JSON.stringify({ ...obj, token_endpoint_auth_method: "none" });
}

export const dcrInterceptRoute = new Elysia().post(
  "/api/auth/oauth2/register",
  async ({ request }) => {
    const original = await request.text();
    const rewritten = coerceConfidentialDcrToPublic(original);
    // Content-Length is a forbidden request header — the runtime sets it
    // automatically from the new body, so no manual handling is needed.
    return auth.handler(
      new Request(request.url, {
        method: "POST",
        headers: request.headers,
        body: rewritten,
      })
    );
  },
  // parse: "none" applies to every body-consuming handler registered ahead of
  // Elysia's JSON parser — the /mcp POST is not the only case. Without it,
  // Elysia drains the body before `await request.text()` can read it,
  // producing a silent `TypeError: Body already used`.
  { parse: "none" }
);
```

Wire it in **before** `.mount(auth.handler)`. Elysia evaluates handlers in
registration order when routes share the same path, so the explicit DCR route
must be registered first to intercept before the mounted auth handler catches
it:

```typescript
const app = new Elysia()
  // ... cors, session middleware ...
  .use(dcrInterceptRoute) // must come before the mounted auth handler
  .mount(auth.handler)
  .use(resourceMetadataRoute)
  .use(authServerMetadataRoute)
  .use(mcpRoutes);
```

**Why this is safe:** MCP's spec (2025-06-18 §3.3) requires PKCE, and OAuth 2.1
recommends public + PKCE for native/desktop apps. Coercing a confidential client
with no authenticated secret into a public PKCE client is a tightening of the
client posture, not a loosening.

**Validate:**

- [ ] `curl -X POST <host>/api/auth/oauth2/register -H "content-type: application/json" -d '{"token_endpoint_auth_method":"client_secret_post","redirect_uris":["https://example.com/cb"],"grant_types":["authorization_code","refresh_token"],"response_types":["code"]}'`
      returns **200** with `"token_endpoint_auth_method": "none"` in the
      response
- [ ] Claude Desktop "Add custom connector" completes the OAuth flow and tool
      calls succeed
- [ ] Claude Code and MCP Inspector still connect (no regression)

**5.4 Bearer token resolution — JWT-first, userinfo fallback (required if you
support Desktop)**

Earlier phases assumed the session middleware resolves bearer tokens via
BetterAuth's `/oauth2/userinfo` endpoint. That works for Claude Code (which
requests `openid profile email`) but fails for Claude Desktop (which requests
`profile email offline_access`) — BetterAuth hardcodes an `openid` scope
requirement on `/oauth2/userinfo` and responds **403** otherwise.

The fix is a two-strategy resolver:

1. **Verify the bearer as a signed JWT** against BetterAuth's JWKS. When the
   token request includes `resource=<mcp-url>`, the oauth-provider plugin issues
   a signed, audience-bound JWT — the signature is the authority, so no scope
   check is imposed. This covers MCP access tokens.
2. **Fall back to `/oauth2/userinfo`** for opaque tokens issued to first-party
   flows that didn't pass `resource`. No up-front sniffing — the verifier's
   failure _is_ the routing signal.

**Install the JWT library:**

```bash
bun add jose
```

**The verifier** (`src/core/http/session.ts`):

```typescript
import { env } from "@core/config";
import {
  createRemoteJWKSet,
  type JWTPayload,
  type JWTVerifyGetKey,
  jwtVerify,
} from "jose";

// `aud` must match the Protected Resource Metadata `resource` field AND the
// `validAudiences` entry on the BetterAuth oauthProvider plugin. The three
// must be kept in sync — a drift produces silent aud-mismatch verify failures
// that look like "invalid token."
const JWT_ISSUER = () => `${env.BETTER_AUTH_URL}/api/auth`;
const JWT_AUDIENCE = () => `${env.BETTER_AUTH_URL}/api/mcp`;
const JWKS_URL = () => `${env.BETTER_AUTH_URL}/api/auth/jwks`;

let _jwks: JWTVerifyGetKey | null = null;
function defaultKeyResolver(): JWTVerifyGetKey {
  // `createRemoteJWKSet` handles fetch, in-process cache, and cooldown.
  // No custom cache layer is needed.
  if (!_jwks) _jwks = createRemoteJWKSet(new URL(JWKS_URL()));
  return _jwks;
}

/**
 * Verify a bearer access token as a signed JWT from BetterAuth. Returns the
 * payload on success, `null` on any failure (malformed, wrong iss/aud,
 * expired, or plainly not a JWT). Silent so callers can fall back to
 * userinfo resolution for opaque tokens.
 *
 * `keyResolver` is injectable so tests can supply a local JWKS with a known
 * keypair.
 */
export async function verifyMcpAccessToken(
  token: string,
  keyResolver: JWTVerifyGetKey = defaultKeyResolver()
): Promise<JWTPayload | null> {
  try {
    const { payload } = await jwtVerify(token, keyResolver, {
      issuer: JWT_ISSUER(),
      audience: JWT_AUDIENCE(),
    });
    return payload;
  } catch {
    return null;
  }
}
```

**The resolver** (`src/core/http/guards.ts`) — composed into your existing guard
middleware as a fallback after the cookie-session path:

```typescript
import { env } from "@core/config";
import { db } from "@core/db";
import { auth } from "@features/auth";
import { user as userTable } from "@features/auth/db";
import { eq } from "drizzle-orm";
import { verifyMcpAccessToken } from "./session";

// Your user type — shape depends on your BetterAuth plugin set.
interface AppUser {
  id: string;
  email: string;
  role?: string | null;
  banned?: boolean | null;
  banExpires?: Date | null;
}

async function resolveSubViaUserinfo(
  authHeader: string
): Promise<string | null> {
  try {
    // Route through auth.handler for consistency with other internal calls —
    // auth.handler dispatches by path, so the host is effectively ignored,
    // but keeping it aligned with BETTER_AUTH_URL avoids a maintenance hazard
    // if BetterAuth ever adds origin validation.
    const response = await auth.handler(
      new Request(
        new URL("/api/auth/oauth2/userinfo", env.BETTER_AUTH_URL).toString(),
        { headers: { authorization: authHeader } }
      )
    );
    if (!response.ok) return null;
    const userInfo = (await response.json()) as { sub?: unknown };
    return typeof userInfo.sub === "string" && userInfo.sub
      ? userInfo.sub
      : null;
  } catch {
    return null;
  }
}

// BetterAuth's cookie-session path rejects banned users whose ban hasn't
// expired. The Bearer path has to enforce the same rule explicitly, or
// time-limited bans leak into admin authorization via the OAuth route.
function isCurrentlyBanned(
  user: Pick<AppUser, "banned" | "banExpires">
): boolean {
  if (user.banned !== true) return false;
  if (!user.banExpires) return true;
  return user.banExpires.getTime() > Date.now();
}

/**
 * Resolve a user from an OAuth Bearer access token. Two strategies tried
 * in order:
 *   1. Verify as signed JWT against JWKS — covers MCP tokens issued with
 *      `resource=<mcp-url>`, which don't carry the `openid` scope.
 *   2. `/oauth2/userinfo` — covers opaque tokens issued to first-party flows.
 * Returns null if the header is missing, neither strategy resolves a sub,
 * or the user doesn't exist / is banned.
 */
export async function resolveOAuthUser(
  request: Request
): Promise<AppUser | null> {
  const authHeader = request.headers.get("authorization");
  if (!authHeader?.startsWith("Bearer ")) return null;
  const token = authHeader.slice("Bearer ".length);

  try {
    const payload = await verifyMcpAccessToken(token);
    let sub: string | null =
      typeof payload?.sub === "string" ? payload.sub : null;
    if (!sub) sub = await resolveSubViaUserinfo(authHeader);
    if (!sub) return null;

    const [user] = await db
      .select()
      .from(userTable)
      .where(eq(userTable.id, sub))
      .limit(1);
    if (!user) return null;
    if (isCurrentlyBanned(user)) return null;
    return user as AppUser;
  } catch {
    return null;
  }
}
```

**Wire into the session middleware.** Your existing guard (Elysia `derive` hook,
Fastify pre-handler, or equivalent) should run the cookie-session check first
and fall back to `resolveOAuthUser` for Bearer requests — returning the same
`{ user, session }` shape either way (Bearer path has `session: null`):

```typescript
export const requireAuth = new Elysia({ name: "guard:auth" }).derive(
  { as: "scoped" },
  async ({ request }) => {
    const session = await auth.api.getSession({ headers: request.headers });
    if (session?.user) {
      return { user: session.user as AppUser, session: session.session };
    }

    const oauthUser = await resolveOAuthUser(request);
    if (!oauthUser) throw APIError.unauthorized("Not authenticated");
    return { user: oauthUser, session: null };
  }
);
```

**Alignment contract (critical):**

| Setting                             | Must equal                     |
| ----------------------------------- | ------------------------------ |
| JWT `aud` claim                     | `${BETTER_AUTH_URL}/api/mcp`   |
| PRM `resource` field (Phase 5.1)    | `${BETTER_AUTH_URL}/api/mcp`   |
| `validAudiences` on `oauthProvider` | `[${BETTER_AUTH_URL}/api/mcp]` |
| JWT `iss` claim                     | `${BETTER_AUTH_URL}/api/auth`  |

A drift in any of these produces `jwtVerify` failures that look
indistinguishable from "bad token" — and because the resolver falls back to
userinfo silently, the only symptom is a 401 on what should be a valid Bearer
request.

**Validate:**

- [ ] MCP tokens issued with `resource=${BETTER_AUTH_URL}/api/mcp` verify
      against JWKS and resolve to the expected `sub`
- [ ] Opaque tokens issued to first-party flows still resolve via userinfo (no
      regression)
- [ ] Claude Desktop, after completing OAuth, can call tools (no 403 on the
      first authenticated tool invocation)
- [ ] A banned user's Bearer token returns 401, matching the cookie-session
      behavior
- [ ] Unit test with an injected local JWKS + known keypair verifies the full
      resolver chain without network I/O

### Phase 6: Testing

**6.1 Unit tests with InMemoryTransport**

The MCP SDK provides `InMemoryTransport` for testing without HTTP:

```typescript
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

async function createTestClient(oauthUserId: string) {
  const server = createMCPServer(oauthUserId);
  const [clientTransport, serverTransport] =
    InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "test", version: "1.0.0" });

  await Promise.all([
    client.connect(clientTransport),
    server.connect(serverTransport),
  ]);

  return client;
}

// Test categories to cover:
// 1. Authentication — valid key, invalid key, revoked key, cross-user rejection
// 2. Session management — creation, expiry, invalid session
// 3. Permission enforcement — each tool checks its required permission
// 4. Resource access — subtree model, parent chain traversal
// 5. Multi-tenant isolation — User A cannot see User B's data
// 6. Tool functionality — each tool returns correct data shape
```

**6.2 Manual testing with curl**

```bash
# List tools (requires auth)
curl -X POST https://your-api.com/api/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_OAUTH_TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

# Authenticate with agent key
curl -X POST https://your-api.com/api/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_OAUTH_TOKEN" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"authenticate","arguments":{"agentKey":"mcp_..."}}}'
```

**6.3 Testing with Claude Code**

Create `.mcp.json` in your project:

```json
{
  "your-app": {
    "url": "https://your-api.com/api/mcp"
  }
}
```

Claude Code will discover the OAuth endpoints automatically from the 401
response and perform the PKCE flow in a browser.

**6.4 Testing with Claude Desktop**

Claude Desktop's remote connector has operational constraints that don't apply
to Claude Code:

- **HTTPS required.** Desktop refuses non-HTTPS MCP URLs outright. Local testing
  needs a tunnel (cloudflared, ngrok) or a deployed endpoint; a plain
  `http://localhost:...` connector fails before any OAuth begins.
- **The public host must match everywhere.** Once you pick a tunnel URL,
  `BETTER_AUTH_URL`, the JWT `aud` claim, the oauthProvider `validAudiences`
  entry, and the PRM `resource` field must **all** use the same host. A mismatch
  produces aud-verify failures indistinguishable from a bad token.

Quick checklist when swapping hosts:

```
export BETTER_AUTH_URL=https://<tunnel-host>
# restart the API so createRemoteJWKSet, JWT_AUDIENCE(), and the metadata
# helpers all re-read env on boot.
```

**6.5 Client user-agent taxonomy + diagnostic logging**

Claude Desktop's connection spans three distinct user-agents hitting different
endpoints, and failures along the way are silent. A gated request-logging hook
is the cheapest way to make the sequence visible when something breaks:

| User-Agent         | Source            | Endpoints hit                         |
| ------------------ | ----------------- | ------------------------------------- |
| `python-httpx/...` | claude.ai backend | `/api/auth/oauth2/register`, `/token` |
| Browser UA         | User's browser    | `/authorize`, consent page            |
| `Claude-User`      | Desktop app       | `/api/mcp` (actual tool calls)        |

Drop-in diagnostic hook:

```typescript
// Enable only when MCP_DEBUG=1 to avoid logging normal traffic.
if (env.MCP_DEBUG === "1") {
  app.onRequest(({ request }) => {
    const url = new URL(request.url);
    if (
      url.pathname.startsWith("/api/mcp") ||
      url.pathname.startsWith("/api/auth/oauth2") ||
      url.pathname.startsWith("/.well-known/")
    ) {
      console.log(
        `[mcp-debug] ${request.method} ${url.pathname} ua=${request.headers.get("user-agent")}`
      );
    }
  });
}
```

With this in place, a silent "Couldn't reach the MCP server" becomes a legible
trace: "DCR call returned 401", "userinfo returned 403", "path-scoped well-known
404", etc.

**Validate:**

- [ ] Unit tests pass for all tool categories
- [ ] curl requests return expected responses
- [ ] Claude Code can connect, authenticate, and use tools
- [ ] Claude Desktop can connect over HTTPS, complete OAuth, and call tools
- [ ] Cross-user isolation verified with two separate accounts

## Integration Points

### With Your Existing Auth System

The MCP endpoint uses your existing session middleware to resolve the OAuth
user. The specific integration depends on your auth library:

- **BetterAuth:** `auth.api.getSession({ headers: request.headers })` for
  cookies, or route through `auth.handler` for OAuth bearer tokens
- **NextAuth/Lucia/etc.:** Use your existing session middleware — the MCP routes
  just need the user ID

### With Your Data Model

Your service layer methods should follow this pattern:

```typescript
// Every method takes ownerId — no exceptions
async getById(id: string, ownerId: string) {
  return db.select().from(items)
    .where(and(
      eq(items.id, id),
      eq(items.ownerId, ownerId),
      isNull(items.deletedAt),  // If using soft deletes
    ))
    .limit(1);
}
```

### With Agent Key Provisioning

You need a way for users to create agents, define roles, and generate API keys.
This can be:

- A page in your existing web admin/settings
- A desktop or mobile app UI
- API endpoints for programmatic management

The recipe covers the auth _validation_ side. Key _generation_ is:

```typescript
import { randomBytes } from "crypto";
import bcrypt from "bcryptjs";

const KEY_PREFIX = "mcp_";
const KEY_LENGTH = 60; // hex characters

function generateAgentKey(): string {
  return KEY_PREFIX + randomBytes(KEY_LENGTH / 2).toString("hex");
}

// When creating a membership:
const key = generateAgentKey();
const keyHash = await bcrypt.hash(key, 12);
const keyPrefix = key.substring(0, 8);
// Store keyHash, keyPrefix in the membership row
// Show the full key to the user once — it cannot be recovered
```

## Gotchas & Important Notes

- **Elysia's body-parser drains any POST body before a handler can read it.**
  The MCP POST route is the most visible case (symptom:
  `-32700 Parse error: Invalid JSON` despite a clean 200), but the same rule
  applies to every body-consuming handler registered ahead of the mounted
  BetterAuth handler — notably the DCR intercept in Phase 5.3 (symptom:
  `TypeError: Body already used` when calling `request.text()`). Pass
  `{ parse: "none" }` as the third argument on any such POST route so Elysia
  skips body parsing there. GET and DELETE don't need this — they have no body.

- **MCP SDK expects Node.js HTTP on older versions.** If you see
  `TypeError: req.on is not a function` or `res.writeHead is not a function`,
  you need the transport adapter from Phase 2. SDK 1.30+ includes
  `WebStandardStreamableHTTPServerTransport` which eliminates this issue.

- **bcrypt is slow without prefix prefiltering.** bcrypt with 12 rounds takes
  ~250ms per comparison. Validating one key against 100 memberships without
  prefiltering = 25 seconds. Always store and filter by `key_prefix`.

- **Zod 4 is required for MCP SDK 1.26+.** The SDK uses Zod 4 internally for
  tool parameter validation. If your project is on Zod 3, this is a
  monorepo-wide upgrade that must happen before MCP integration.

- **Sessions must be database-backed.** In-memory session storage works on one
  server instance but fails after restart or on a different instance. Always use
  PostgreSQL for session storage in API servers.

- **Missing ownerId filter leaks data between users.** The most dangerous bug in
  a multi-tenant system. Establish the convention that every service method
  takes `ownerId` and every query includes it. Write tests specifically for
  isolation.

- **MCP client connections can be fragile.** The connection flow involves
  multiple round-trips (OAuth discovery, PKCE flow, MCP initialization). Proxy
  layers add failure modes. Support direct HTTP connections where possible.

- **Permission list may outpace tool implementation.** If your auth system
  defines permissions like `create_document` but the tool doesn't exist yet,
  include those permissions in the denied list in the authenticate response so
  agents know what's not available.

- **The 401 response format matters.** MCP clients parse the `WWW-Authenticate`
  header to find the resource metadata URL. The exact format is:
  `Bearer resource_metadata="https://..."` with the URL in double quotes. If
  this is malformed, clients can't discover your OAuth server.

- **Well-known endpoints live at the root AND path-scoped per resource.** RFC
  8615 requires `/.well-known/*` at the domain root — that covers Claude Code,
  MCP Inspector, and any client that honors the
  `WWW-Authenticate: resource_metadata=<url>` hint. Claude Desktop ignores the
  hint and constructs its own URL by appending the resource path
  (`/.well-known/oauth-protected-resource/api/mcp`,
  `/.well-known/oauth-authorization-server/api/mcp`), so register both forms.
  Register on the app root, not in a prefixed route group.

- **Claude Desktop silently fails without DCR coercion.** Desktop's remote
  connector sends a confidential-client DCR
  (`token_endpoint_auth_method: "client_secret_post"`) without authentication,
  which BetterAuth's OAuth provider rejects with 401. Claude.ai's backend aborts
  silently on non-2xx DCR, so the only symptom is "Couldn't reach the MCP
  server." Claude Code and MCP Inspector aren't affected. See Phase 5.3 for the
  intercept that rewrites the DCR body to a public PKCE client.

## External Documentation

- **MCP Specification:** https://modelcontextprotocol.io/
- **MCP TypeScript SDK:** https://github.com/modelcontextprotocol/typescript-sdk
- **RFC 9728 (Protected Resource Metadata):**
  https://www.rfc-editor.org/rfc/rfc9728
- **RFC 8414 (OAuth Server Metadata):** https://www.rfc-editor.org/rfc/rfc8414
- **bcryptjs:** https://github.com/dcodeIO/bcrypt.js
- **Drizzle ORM:** https://orm.drizzle.team
- **Elysia:** https://elysiajs.com
