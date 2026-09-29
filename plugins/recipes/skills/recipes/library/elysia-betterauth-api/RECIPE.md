# Elysia + BetterAuth API Recipe

## Purpose

Implement a production-ready API server using Bun, Elysia, BetterAuth, and
Drizzle ORM on PostgreSQL. This recipe handles the integration glue between
these technologies - the parts that aren't obvious from reading each library's
docs individually.

## When to Use

- Starting a new API project on Bun with authentication needs
- Adding BetterAuth to an existing Elysia app
- Scaffolding the core infrastructure for a backend service
- The user references "Elysia BetterAuth recipe" or similar

## Technology Stack

| Layer          | Technology                            | Version |
| -------------- | ------------------------------------- | ------- |
| Runtime        | Bun                                   | 1.2+    |
| Framework      | Elysia                                | 1.4+    |
| Authentication | BetterAuth + Drizzle adapter          | 1.4+    |
| ORM            | Drizzle ORM with postgres.js          | 0.45+   |
| Database       | PostgreSQL                            | 15+     |
| Validation     | Zod (env/business) + TypeBox (routes) | 3.24+   |
| Migrations     | Drizzle Kit                           | 0.31+   |

## Architecture Overview

The recipe implements a 6-layer architecture:

```
Layer 1: Database (Drizzle + PostgreSQL)
    ↑
Layer 2: Auth (BetterAuth + Drizzle Adapter)
    ↑
Layer 3: Session Middleware (Elysia Derive)
    ↑
Layer 4: Auth Guards (Composable Elysia Plugins)
    ↑
Layer 5: Route Handlers (Elysia + TypeBox)
    ↑
Layer 6: App Entry Point (Elysia Pipeline)
```

Plus cross-cutting concerns:

- **Error Handling** - APIError class with gRPC-style codes
- **Event Bus** - Typed pub/sub for decoupled side-effects
- **API Client** - Eden Treaty for type-safe clients

## Implementation Process

### Phase 1: Project Foundation

**1.1 Initialize and install dependencies**

```bash
mkdir my-api && cd my-api
bun init -y
```

Set `"type": "module"` in `package.json`.

Install core dependencies:

```bash
# Framework
bun add elysia @elysiajs/cors

# Auth
bun add better-auth

# Database
bun add drizzle-orm postgres

# Validation & Config
bun add zod dotenv-flow

# Dev dependencies
bun add -d drizzle-kit typescript @types/bun
```

Optional:

```bash
bun add @elysiajs/openapi        # OpenAPI docs
bun add @elysiajs/eden           # Type-safe API client
bun add @better-auth/expo        # Mobile app support
```

**1.2 Configure TypeScript**

Create `tsconfig.json`. The path aliases are critical for clean imports:

```json
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "declaration": true,
    "declarationMap": true,
    "outDir": "dist",
    "rootDir": "src",
    "types": ["bun-types"],
    "baseUrl": ".",
    "paths": {
      "@/*": ["src/*"],
      "@core/*": ["src/core/*"],
      "@features/*": ["src/features/*"]
    }
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
```

Bun resolves these path aliases natively from tsconfig - no additional tooling
needed.

**1.3 Create directory structure**

```bash
mkdir -p src/core/{config,db,events,http}
mkdir -p src/features/{auth,notifications}
mkdir -p src/routes
mkdir -p scripts
```

**1.4 Set up package scripts**

```json
{
  "scripts": {
    "dev": "bun run --watch src/index.ts",
    "start": "bun run src/index.ts",
    "build": "bun build src/index.ts --outdir dist --target bun",
    "check-types": "tsc --noEmit",
    "test": "bun test",
    "db:generate": "drizzle-kit generate",
    "db:migrate": "drizzle-kit migrate",
    "db:push": "drizzle-kit push",
    "db:studio": "drizzle-kit studio"
  }
}
```

### Phase 2: Core Infrastructure

Build the `src/core/` layer. This is framework infrastructure with no business
logic.

**2.1 Environment config** (`src/core/config/env.ts`)

Use Zod to validate environment variables at startup. This crashes fast with
clear errors instead of failing mysteriously at runtime.

```typescript
import { z } from "zod";

const EnvSchema = z.object({
  BUN_PORT: z.coerce.number(),
  DATABASE_URL: z
    .string()
    .refine(
      (url) => url.startsWith("postgres://") || url.startsWith("postgresql://"),
      {
        message: "DATABASE_URL must be a postgres:// or postgresql:// URL",
      }
    ),
  BETTER_AUTH_SECRET: z.string(),
  BETTER_AUTH_URL: z.string().url(),
  ALLOWED_ORIGINS: z.string(),
});

export type Env = z.infer<typeof EnvSchema>;

function parseEnv(): Env {
  const result = EnvSchema.safeParse(process.env);
  if (!result.success) {
    console.error("Invalid environment variables:");
    for (const issue of result.error.issues) {
      console.error(`   ${issue.path.join(".")}: ${issue.message}`);
    }
    process.exit(1);
  }
  return result.data;
}

export const env = parseEnv();
export const allowedOrigins = env.ALLOWED_ORIGINS.split(",").map((s) =>
  s.trim()
);
```

Create `src/core/config/index.ts`:

```typescript
export { env, allowedOrigins, type Env } from "./env";
```

Create `.env.example`:

```bash
BUN_PORT=3011
DATABASE_URL=postgresql://user:password@localhost:5432/mydb
BETTER_AUTH_SECRET="generate-a-strong-secret-here"
BETTER_AUTH_URL="http://localhost:3011"
ALLOWED_ORIGINS="http://localhost:3000,http://localhost:5173"
```

**2.2 Database client** (`src/core/db/client.ts`)

The key pattern: feature schemas are defined in `features/*/db.ts` and combined
here into a single Drizzle instance.

```typescript
import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import { env } from "@core/config";
import * as authSchema from "@features/auth/db";
// Add more feature schemas as they're created:
// import * as postsSchema from '@features/posts/db';

const client = postgres(env.DATABASE_URL);

const schema = {
  ...authSchema,
  // ...postsSchema,
};

export const db = drizzle(client, { schema });
export type Database = typeof db;
```

Create `src/core/db/index.ts`:

```typescript
export { db, type Database } from "./client";
export * from "@features/auth/db";
```

**2.3 Error handling** (`src/core/http/api-errors.ts`)

A structured error system with gRPC-style codes that map to HTTP status codes.
This gives consistent error responses across all endpoints.

```typescript
import { ZodError } from "zod";

export enum ErrCode {
  OK = "ok",
  Canceled = "canceled",
  Unknown = "unknown",
  InvalidArgument = "invalid_argument",
  DeadlineExceeded = "deadline_exceeded",
  NotFound = "not_found",
  AlreadyExists = "already_exists",
  PermissionDenied = "permission_denied",
  ResourceExhausted = "resource_exhausted",
  FailedPrecondition = "failed_precondition",
  Aborted = "aborted",
  OutOfRange = "out_of_range",
  Unimplemented = "unimplemented",
  Internal = "internal",
  Unavailable = "unavailable",
  DataLoss = "data_loss",
  Unauthenticated = "unauthenticated",
}

const statusByCode: Record<ErrCode, number> = {
  [ErrCode.OK]: 200,
  [ErrCode.Canceled]: 408,
  [ErrCode.Unknown]: 500,
  [ErrCode.InvalidArgument]: 400,
  [ErrCode.DeadlineExceeded]: 504,
  [ErrCode.NotFound]: 404,
  [ErrCode.AlreadyExists]: 409,
  [ErrCode.PermissionDenied]: 403,
  [ErrCode.ResourceExhausted]: 429,
  [ErrCode.FailedPrecondition]: 412,
  [ErrCode.Aborted]: 409,
  [ErrCode.OutOfRange]: 400,
  [ErrCode.Unimplemented]: 501,
  [ErrCode.Internal]: 500,
  [ErrCode.Unavailable]: 503,
  [ErrCode.DataLoss]: 500,
  [ErrCode.Unauthenticated]: 401,
};

export function toHttpStatus(code: ErrCode): number {
  return statusByCode[code] ?? 500;
}

export class APIError extends Error {
  public readonly code: ErrCode;

  constructor(code: ErrCode, msg: string, cause?: Error) {
    super(msg, { cause });
    this.code = code;
    Object.setPrototypeOf(this, APIError.prototype);
  }

  static notFound(msg: string, cause?: Error) {
    return new APIError(ErrCode.NotFound, msg, cause);
  }
  static internal(msg: string, cause?: Error) {
    return new APIError(ErrCode.Internal, msg, cause);
  }
  static invalidArgument(msg: string, cause?: Error) {
    return new APIError(ErrCode.InvalidArgument, msg, cause);
  }
  static permissionDenied(msg: string, cause?: Error) {
    return new APIError(ErrCode.PermissionDenied, msg, cause);
  }
  static unauthenticated(msg: string, cause?: Error) {
    return new APIError(ErrCode.Unauthenticated, msg, cause);
  }
  static alreadyExists(msg: string, cause?: Error) {
    return new APIError(ErrCode.AlreadyExists, msg, cause);
  }
  static unimplemented(msg: string, cause?: Error) {
    return new APIError(ErrCode.Unimplemented, msg, cause);
  }
  // Add more static factories as needed
}

export interface ErrorResponse {
  error: { code: ErrCode; message: string; issues?: unknown[] };
}

export function formatError(err: unknown): {
  body: ErrorResponse;
  status: number;
} {
  if (err instanceof ZodError) {
    return {
      body: {
        error: {
          code: ErrCode.InvalidArgument,
          message: "Invalid request",
          issues: err.issues,
        },
      },
      status: 400,
    };
  }
  if (err instanceof APIError) {
    return {
      body: { error: { code: err.code, message: err.message } },
      status: toHttpStatus(err.code),
    };
  }
  console.error(err);
  return {
    body: {
      error: { code: ErrCode.Internal, message: "Internal server error" },
    },
    status: 500,
  };
}
```

**2.4 Session middleware** (`src/core/http/session.ts`)

This is the bridge between BetterAuth and Elysia. It extracts the current user
from every request via Elysia's `.derive()`.

```typescript
import { Elysia } from "elysia";
import { auth, type User } from "@features/auth";

export const sessionMiddleware = new Elysia({ name: "session" }).derive(
  { as: "global" },
  async ({ request }) => {
    const session = await auth.api.getSession({ headers: request.headers });
    return {
      user: (session?.user ?? null) as User | null,
      session: session?.session ?? null,
    };
  }
);
```

**IMPORTANT:** `as: 'global'` means this runs on EVERY request. This is
intentional - every route needs `user` in context, even if it's `null` for
public routes.

**2.5 Auth guards** (`src/core/http/guards.ts`)

Composable Elysia plugins that enforce authentication and authorization. Guards
use `as: 'scoped'` so they only apply to the route group that `.use()`s them.

```typescript
import { Elysia } from "elysia";
import { sessionMiddleware } from "./session";
import { ErrCode } from "./api-errors";

export const requireAuth = new Elysia({ name: "guard:auth" })
  .use(sessionMiddleware)
  .onBeforeHandle({ as: "scoped" }, ({ user, set }) => {
    if (!user) {
      set.status = 401;
      return {
        error: {
          code: ErrCode.Unauthenticated,
          message: "Authentication required",
        },
      };
    }
    return undefined;
  });

export const requireAdmin = new Elysia({ name: "guard:admin" })
  .use(sessionMiddleware)
  .onBeforeHandle({ as: "scoped" }, ({ user, set }) => {
    if (!user) {
      set.status = 401;
      return {
        error: {
          code: ErrCode.Unauthenticated,
          message: "Authentication required",
        },
      };
    }
    if (user.role !== "admin") {
      set.status = 403;
      return {
        error: {
          code: ErrCode.PermissionDenied,
          message: "Admin access required",
        },
      };
    }
    return undefined;
  });

export const requireRoles = (...roles: string[]) => {
  const allowedRoles = new Set(roles);
  return new Elysia({ name: `guard:roles:${roles.join(",")}` })
    .use(sessionMiddleware)
    .onBeforeHandle({ as: "scoped" }, ({ user, set }) => {
      if (!user) {
        set.status = 401;
        return {
          error: {
            code: ErrCode.Unauthenticated,
            message: "Authentication required",
          },
        };
      }
      if (!allowedRoles.has(user.role ?? "user")) {
        set.status = 403;
        return {
          error: {
            code: ErrCode.PermissionDenied,
            message: "Insufficient permissions",
          },
        };
      }
      return undefined;
    });
};
```

**CRITICAL DISTINCTION:** Session middleware is `as: 'global'` (every route gets
`user`). Guards are `as: 'scoped'` (only applied where `.use()`d). Getting this
wrong breaks public endpoints.

Create `src/core/http/index.ts`:

```typescript
export { sessionMiddleware } from "./session";
export { requireAuth, requireAdmin, requireRoles } from "./guards";
export {
  APIError,
  ErrCode,
  formatError,
  type ErrorResponse,
} from "./api-errors";
```

**2.6 Event bus** (`src/core/events/`)

A typed event bus for decoupling side-effects from features. Auth doesn't need
to know how emails are sent.

`src/core/events/bus.ts`:

```typescript
type Handler<E extends { type: string }> = (event: E) => void | Promise<void>;

export class TypedEventBus<E extends { type: string }> {
  private handlers = new Map<E["type"], Handler<E>[]>();

  on<K extends E["type"]>(
    type: K,
    handler: (event: Extract<E, { type: K }>) => void | Promise<void>
  ) {
    const list = this.handlers.get(type) ?? [];
    list.push(handler as unknown as Handler<E>);
    this.handlers.set(type, list);
  }

  async emit(event: E) {
    const list = this.handlers.get(event.type) ?? [];
    for (const h of list) await h(event as E);
  }
}
```

`src/core/events/types.ts`:

```typescript
// Central registry - add event types here as features grow
export type AppEventMap = {
  "notifications.send-email": {
    email: string;
    subject: string;
    templateId: string;
    data: Record<string, unknown>;
  };
};

export type AppEvent = {
  [K in keyof AppEventMap]: { type: K; payload: AppEventMap[K] };
}[keyof AppEventMap];

export type AppEventType = keyof AppEventMap;
export type EventPayloadOf<T extends AppEventType> = AppEventMap[T];
```

`src/core/events/index.ts`:

```typescript
import { TypedEventBus } from "./bus";
import type { AppEvent, AppEventType, EventPayloadOf } from "./types";

export { TypedEventBus } from "./bus";
export type { AppEvent, AppEventType, EventPayloadOf } from "./types";

export const bus = new TypedEventBus<AppEvent>();

export function on<K extends AppEventType>(
  type: K,
  handler: (payload: EventPayloadOf<K>) => void | Promise<void>
) {
  bus.on(type as AppEventType, (e) =>
    handler((e as AppEvent).payload as EventPayloadOf<K>)
  );
}

export function emit<K extends AppEventType>(
  type: K,
  payload: EventPayloadOf<K>
) {
  return bus.emit({ type, payload } as AppEvent);
}
```

### Phase 3: Auth Feature

Build the `src/features/auth/` module. This is the most important integration
point.

**3.1 Auth schema** (`src/features/auth/db.ts`)

BetterAuth requires specific table names and columns. Plugin columns must be
added to the Drizzle schema manually.

```typescript
import { pgTable, text, boolean, timestamp } from "drizzle-orm/pg-core";

export const user = pgTable("user", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  email: text("email").notNull().unique(),
  emailVerified: boolean("email_verified").notNull().default(false),
  image: text("image"),
  createdAt: timestamp("created_at").notNull().defaultNow(),
  updatedAt: timestamp("updated_at").notNull().defaultNow(),
  // admin() plugin fields:
  role: text("role"),
  banned: boolean("banned"),
  banReason: text("ban_reason"),
  banExpires: timestamp("ban_expires"),
  // username() plugin fields:
  username: text("username").unique(),
  displayUsername: text("display_username"),
});

export const session = pgTable("session", {
  id: text("id").primaryKey(),
  expiresAt: timestamp("expires_at").notNull(),
  token: text("token").notNull().unique(),
  createdAt: timestamp("created_at").notNull(),
  updatedAt: timestamp("updated_at").notNull(),
  ipAddress: text("ip_address"),
  userAgent: text("user_agent"),
  userId: text("user_id")
    .notNull()
    .references(() => user.id, { onDelete: "cascade" }),
  impersonatedBy: text("impersonated_by"), // admin() plugin
});

export const account = pgTable("account", {
  id: text("id").primaryKey(),
  accountId: text("account_id").notNull(),
  providerId: text("provider_id").notNull(),
  userId: text("user_id")
    .notNull()
    .references(() => user.id, { onDelete: "cascade" }),
  accessToken: text("access_token"),
  refreshToken: text("refresh_token"),
  idToken: text("id_token"),
  accessTokenExpiresAt: timestamp("access_token_expires_at"),
  refreshTokenExpiresAt: timestamp("refresh_token_expires_at"),
  scope: text("scope"),
  password: text("password"),
  createdAt: timestamp("created_at").notNull(),
  updatedAt: timestamp("updated_at").notNull(),
});

export const verification = pgTable("verification", {
  id: text("id").primaryKey(),
  identifier: text("identifier").notNull(),
  value: text("value").notNull(),
  expiresAt: timestamp("expires_at").notNull(),
  createdAt: timestamp("created_at").notNull().defaultNow(),
  updatedAt: timestamp("updated_at").notNull().defaultNow(),
});

// Only needed if using jwt() plugin
export const jwks = pgTable("jwks", {
  id: text("id").primaryKey(),
  publicKey: text("public_key").notNull(),
  privateKey: text("private_key").notNull(),
  createdAt: timestamp("created_at").notNull().defaultNow(),
});

export const authSchema = { user, session, account, verification, jwks };
```

**IMPORTANT:** When adding BetterAuth plugins, check the plugin docs for
required columns and add them to your Drizzle schema. The schema must match what
BetterAuth expects.

**3.2 Auth adapter** (`src/features/auth/adapter.ts`)

This is the central integration point. BetterAuth uses your Drizzle instance to
manage its own tables.

```typescript
import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { admin, username, bearer, jwt } from "better-auth/plugins";
import { db } from "@core/db";
import { env, allowedOrigins } from "@core/config";
import * as authSchema from "./db";

export const auth: ReturnType<typeof betterAuth> = betterAuth({
  secret: env.BETTER_AUTH_SECRET,

  // KEY INTEGRATION: BetterAuth uses Drizzle to talk to Postgres
  database: drizzleAdapter(db, {
    provider: "pg",
    schema: authSchema,
  }),

  emailAndPassword: {
    enabled: true,
  },

  user: {
    additionalFields: {
      // Add custom user fields here - must match your Drizzle schema
      username: { type: "string", required: true },
    },
  },

  plugins: [
    admin(), // Role management, banning, impersonation
    username(), // Username support
    bearer(), // Bearer token auth for API clients
    jwt({
      // JWT with JWKS (optional - for third-party service auth)
      jwks: { keyPairConfig: { alg: "RS256" } },
    }),
    // expo(),    // Uncomment for React Native / Expo support
  ],

  trustedOrigins: [...allowedOrigins],
});
```

**3.3 Auth types** (`src/features/auth/types.ts`):

```typescript
import { auth } from "./adapter";
import { user } from "./db";

export type User = typeof auth.$Infer.Session.user;
export type Session = typeof auth.$Infer.Session.session;
export type Account = typeof user.$inferSelect;
```

**3.4 Auth index** (`src/features/auth/index.ts`):

```typescript
export { auth } from "./adapter";
export type { User, Session } from "./types";
export * from "./db";
```

### Phase 4: Drizzle Kit Configuration

Create `drizzle.config.ts` at the project root:

```typescript
import { defineConfig } from "drizzle-kit";

export default defineConfig({
  out: "./drizzle",
  schema: [
    "./src/features/auth/db.ts",
    // Add more feature schema files as they're created
  ],
  dialect: "postgresql",
  dbCredentials: {
    url: process.env.DATABASE_URL!,
  },
});
```

**IMPORTANT:** Every feature's `db.ts` file must be listed here. Forgetting one
means those tables won't appear in migrations.

Generate and run initial migration:

```bash
bun run db:generate
bun run db:migrate
```

### Phase 5: Routes and Entry Point

**5.1 Example route group** (`src/routes/admin/users.ts`):

```typescript
import { Elysia, t } from "elysia";
import { eq } from "drizzle-orm";
import { requireAdmin } from "@core/http";
import { db, user as userTable } from "@core/db";

export const adminUsersRoutes = new Elysia({ prefix: "/admin/users" })
  .use(requireAdmin)
  .get("/", async () => {
    const users = await db.select().from(userTable);
    return { users, total: users.length };
  })
  .get(
    "/:id",
    async ({ params, set }) => {
      const [foundUser] = await db
        .select()
        .from(userTable)
        .where(eq(userTable.id, params.id))
        .limit(1);
      if (!foundUser) {
        set.status = 404;
        return { message: "User not found" };
      }
      return foundUser;
    },
    {
      params: t.Object({ id: t.String() }),
    }
  );
```

Pattern: Use Elysia's `t` (TypeBox) for route validation. Use Zod for complex
business validation.

**5.2 Route index** (`src/routes/index.ts`):

```typescript
export { adminRoutes } from "./admin";
// Export more route groups as they're created
```

**5.3 App entry point** (`src/index.ts`):

```typescript
import "dotenv-flow/config";

import { Elysia } from "elysia";
import { cors } from "@elysiajs/cors";
import { env, allowedOrigins } from "@core/config";
import { sessionMiddleware } from "@core/http";
import { auth } from "@features/auth";
import { adminRoutes } from "./routes";

// Register event listeners (side-effect import)
// import '@features/notifications/listeners';

const app = new Elysia()
  .use(cors({ origin: allowedOrigins, credentials: true }))
  .use(sessionMiddleware)
  .mount(auth.handler) // BetterAuth at /api/auth/*
  .get("/health", () => ({ status: "ok", timestamp: new Date().toISOString() }))
  .use(adminRoutes)
  .listen({ hostname: "0.0.0.0", port: env.BUN_PORT });

console.log(`API running at ${app.server?.hostname}:${app.server?.port}`);

// Export type for Eden Treaty client
export type App = typeof app;
```

**CRITICAL ORDERING:**

1. `dotenv-flow/config` FIRST (loads env vars before anything reads them)
2. CORS before session middleware
3. Session middleware before `.mount()` and routes
4. `.mount(auth.handler)` - NOT `.use()`. Mount gives BetterAuth full control.
5. Your route groups after BetterAuth mount
6. `export type App` LAST - must be after the full chain for Eden to infer all
   routes

### Phase 6: Type-Safe API Client (Optional)

**Server side** - The `export type App = typeof app` in `index.ts` already
handles this.

**Client side** - In a separate package or the consuming app:

```typescript
import { treaty } from "@elysiajs/eden";
import type { App } from "@my-app/api";

export function createApiClient(baseUrl: string) {
  return treaty<App>(baseUrl, {
    fetch: { credentials: "include" },
  });
}
```

The API's `package.json` must expose types:

```json
{
  "exports": {
    ".": {
      "types": "./src/index.ts",
      "default": "./src/index.ts"
    }
  }
}
```

### Phase 7: Docker Deployment (Optional)

Multi-stage Dockerfile with separate migration and runtime stages:

```dockerfile
FROM node:20-bookworm-slim AS deps
WORKDIR /repo
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/api/package.json ./apps/api/package.json
RUN pnpm install --frozen-lockfile --filter @my-app/api...
COPY apps/api ./apps/api
COPY packages ./packages

FROM deps AS migrate
CMD ["sh", "-lc", "pnpm -C apps/api db:migrate && echo 'migrate: done'"]

FROM oven/bun:1.2 AS build
WORKDIR /repo
COPY --from=deps /repo/node_modules ./node_modules
COPY --from=deps /repo/apps ./apps
COPY --from=deps /repo/packages ./packages
COPY --from=deps /repo/package.json ./package.json
RUN bun --cwd=apps/api run build

FROM oven/bun:1.2 AS runtime
WORKDIR /app
ENV NODE_ENV=production
ENV BUN_PORT=3011
COPY --from=build /repo/apps/api/dist ./dist
EXPOSE 3011
WORKDIR /app/dist
CMD ["bun", "run", "index.js"]
```

If you load files at runtime (templates via `fs.readFileSync`), copy them
separately - `bun build` doesn't bundle them.

## Critical Integration Details

These are the non-obvious parts that trip people up:

### BetterAuth + Drizzle Schema Sync

BetterAuth does NOT auto-create tables. You must:

1. Define tables in Drizzle matching BetterAuth's expected schema
2. Include plugin-specific columns (e.g., `admin()` needs `role`, `banned`)
3. Pass the schema to
   `drizzleAdapter(db, { provider: 'pg', schema: authSchema })`

### `.mount()` vs `.use()` for BetterAuth

`.mount(auth.handler)` gives BetterAuth full control of `/api/auth/*`. Elysia's
TypeBox validation and middleware do NOT apply to mounted handlers. Use `.use()`
for your own route groups only.

### `as: 'global'` vs `as: 'scoped'`

- Session middleware: `as: 'global'` (every route needs `user` in context)
- Guards: `as: 'scoped'` (only protect routes that opt in)

Getting this backwards breaks public endpoints or leaves protected routes open.

### Elysia Plugin Naming

Always name plugins: `new Elysia({ name: 'session' })`. If two route groups both
`.use(sessionMiddleware)`, Elysia deduplicates by name and only runs it once.

### Event Bus Side-Effect Imports

Listener files must be imported for their side-effects:

```typescript
import "@features/notifications/listeners";
```

Without this import, events emit but no one handles them.

### Drizzle Kit Multi-File Schema

Every feature's `db.ts` must be listed in `drizzle.config.ts`. Forgetting a file
means those tables won't appear in generated migrations.

## Adding New Features Checklist

When adding a new feature to a project built with this recipe:

1. Create `src/features/my-feature/db.ts` - Drizzle table definitions
2. Add schema file to `drizzle.config.ts` schema array
3. Import and spread schema in `src/core/db/client.ts`
4. Create `src/features/my-feature/types.ts` - Zod schemas + types
5. Create `src/features/my-feature/service.ts` - Business logic
6. Create `src/features/my-feature/index.ts` - Re-exports
7. Create `src/routes/my-feature/` - Route handlers
8. Wire routes into `src/index.ts` via `.use()`
9. Run `bun run db:generate && bun run db:migrate`

## External Documentation

For the latest APIs and configuration beyond what this recipe covers:

- **Elysia:** https://elysiajs.com
- **BetterAuth:** https://better-auth.com
- **Drizzle ORM:** https://orm.drizzle.team
- **Bun:** https://bun.sh
