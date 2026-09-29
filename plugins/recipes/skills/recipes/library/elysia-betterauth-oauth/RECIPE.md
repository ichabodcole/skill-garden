# BetterAuth OAuth Provider Recipe

## Purpose

Add first-party OAuth 2.1 with PKCE to a BetterAuth + Elysia API so native
clients (desktop, mobile, CLI) can authenticate through the browser and receive
access/refresh tokens. This recipe builds on the elysia-betterauth-api skill and
handles the integration glue between `@better-auth/oauth-provider`, Elysia
routing, client seeding, session middleware changes, and a loopback callback
server for desktop apps.

## When to Use

- Adding OAuth authentication to an existing BetterAuth + Elysia API
- Building a desktop app (Electron, Tauri) that needs browser-based sign-in
- Native clients need access/refresh tokens instead of session cookies
- You need PowerSync or another service that authenticates via JWT + JWKS
- Replacing direct email/password forms in native apps with browser-based login

## Prerequisites

This recipe assumes the base elysia-betterauth-api skill is already implemented.
You should have:

- BetterAuth configured with `drizzleAdapter` and PostgreSQL
- Session middleware with `as: 'global'` derive
- Auth guards (`requireAuth`, etc.)
- The `jwt()` plugin enabled (needed for JWKS)

## Technology Stack

| Layer            | Technology                            | Version |
| ---------------- | ------------------------------------- | ------- |
| OAuth Plugin     | @better-auth/oauth-provider           | 1.4+    |
| PKCE             | OAuth 2.1 / RFC 7636 (S256)           | -       |
| Desktop Callback | Node.js HTTP (RFC 8252 §7.3)          | -       |
| Token Signing    | jose                                  | 5.x+    |
| Key Decryption   | better-auth/crypto (symmetricDecrypt) | 1.4+    |

## Architecture Overview

The OAuth flow adds a browser-mediated authentication layer on top of
BetterAuth's existing session system:

```
Desktop/Native Client                    API Server
─────────────────────                    ──────────
1. Generate PKCE pair
   (code_verifier + S256 challenge)
2. Start loopback HTTP server
   on 127.0.0.1:8789-8799
3. Open browser → ──────────────────→  /api/auth/oauth2/authorize
                                        ↓ (no session? redirect to login page)
                                       /oauth/login (HTML login form)
                                        ↓ (user signs in with email/password)
                                       POST /api/auth/sign-in/email
                                        ↓ (session cookie set)
                                       GET /api/auth/oauth2/authorize
                                        ↓ (issue auth code, redirect)
4. Receive callback ←────────────────  302 → http://127.0.0.1:{port}/callback?code=...&state=...
   on loopback server
5. Exchange code ───────────────────→  POST /api/auth/oauth2/token
                                        (grant_type=authorization_code)
   ←────────────────────────────────   { access_token, refresh_token }
6. Store tokens locally
7. Use access_token ────────────────→  Authorization: Bearer {access_token}
8. Refresh when expired ────────────→  POST /api/auth/oauth2/token
                                        (grant_type=refresh_token)
```

### Key Design Decisions

**Why OAuth for first-party apps?** Native apps shouldn't handle passwords
directly. Browser-based login provides: credential manager support, future SSO
extensibility, session isolation between browser and app, and standard
access/refresh token lifecycle.

**Why loopback redirect (RFC 8252 §7.3)?** Custom URL schemes
(`myapp://callback`) are macOS-only by default and require platform-specific
registration. A loopback HTTP server on `127.0.0.1` works on all platforms
without OS configuration.

**Why 127.0.0.1 instead of localhost?** `localhost` can resolve to `::1` (IPv6)
on some systems, causing callback failures. `127.0.0.1` is unambiguous IPv4.

**Why a port range?** Port 8789 might be in use. The server tries ports
8789-8799 and all ports are pre-registered as valid redirect URIs.

## Data Model

The OAuth Provider plugin adds four tables to the existing BetterAuth schema:

```sql
-- OAuth client registrations (first-party and third-party)
oauth_client (
  id              TEXT PRIMARY KEY,
  client_id       TEXT NOT NULL UNIQUE,  -- Human-readable identifier
  client_secret   TEXT,                  -- NULL for public clients
  redirect_uris   TEXT[] NOT NULL,       -- Allowed callback URLs
  grant_types     TEXT[],                -- ['authorization_code', 'refresh_token']
  response_types  TEXT[],                -- ['code']
  scopes          TEXT[],                -- ['openid', 'profile', 'email', 'offline_access']
  public          BOOLEAN,              -- TRUE for native/SPA clients (no secret)
  skip_consent    BOOLEAN,              -- TRUE for first-party clients
  token_endpoint_auth_method TEXT,       -- 'none' for public clients
  ...timestamps, metadata
)

-- Issued access tokens (hashed before storage)
oauth_access_token (
  id         TEXT PRIMARY KEY,
  token      TEXT UNIQUE,           -- Hashed token value
  client_id  TEXT REFERENCES oauth_client(client_id),
  session_id TEXT REFERENCES session(id),
  user_id    TEXT REFERENCES user(id),
  expires_at TIMESTAMP,
  scopes     TEXT[] NOT NULL,
  ...
)

-- Issued refresh tokens (hashed before storage)
oauth_refresh_token (
  id         TEXT PRIMARY KEY,
  token      TEXT NOT NULL,          -- Hashed token value
  client_id  TEXT REFERENCES oauth_client(client_id),
  session_id TEXT REFERENCES session(id),
  user_id    TEXT REFERENCES user(id),
  expires_at TIMESTAMP,
  revoked    TIMESTAMP,
  scopes     TEXT[] NOT NULL,
  ...
)

-- User consent records (skipped for first-party clients)
oauth_consent (
  id         TEXT PRIMARY KEY,
  client_id  TEXT REFERENCES oauth_client(client_id),
  user_id    TEXT REFERENCES user(id),
  scopes     TEXT[] NOT NULL,
  ...timestamps
)
```

**Important:** Better Auth hashes OAuth tokens before storing them. You cannot
look up tokens by their raw value with a simple `WHERE token = ?` query. Use
Better Auth's APIs for token validation.

## Implementation Process

### Phase 1: Install Dependencies and Add Schema

**1.1 Install the OAuth Provider plugin**

```bash
bun add @better-auth/oauth-provider
```

For the PowerSync integration (Phase 5):

```bash
bun add jose
```

**1.2 Add OAuth tables to Drizzle schema**

Add these tables to your auth schema file (e.g., `src/features/auth/db.ts`):

```typescript
import { pgTable, text, boolean, timestamp, jsonb } from "drizzle-orm/pg-core";

// ... existing tables (user, session, account, verification, jwks) ...

export const oauthClient = pgTable("oauth_client", {
  id: text("id").primaryKey(),
  clientId: text("client_id").notNull().unique(),
  clientSecret: text("client_secret"),
  disabled: boolean("disabled").default(false),
  skipConsent: boolean("skip_consent"),
  enableEndSession: boolean("enable_end_session"),
  scopes: text("scopes").array(),
  userId: text("user_id").references(() => user.id, { onDelete: "cascade" }),
  createdAt: timestamp("created_at"),
  updatedAt: timestamp("updated_at"),
  name: text("name"),
  uri: text("uri"),
  icon: text("icon"),
  contacts: text("contacts").array(),
  tos: text("tos"),
  policy: text("policy"),
  softwareId: text("software_id"),
  softwareVersion: text("software_version"),
  softwareStatement: text("software_statement"),
  redirectUris: text("redirect_uris").array().notNull(),
  postLogoutRedirectUris: text("post_logout_redirect_uris").array(),
  tokenEndpointAuthMethod: text("token_endpoint_auth_method"),
  grantTypes: text("grant_types").array(),
  responseTypes: text("response_types").array(),
  public: boolean("public"),
  type: text("type"),
  referenceId: text("reference_id"),
  metadata: jsonb("metadata"),
});

export const oauthRefreshToken = pgTable("oauth_refresh_token", {
  id: text("id").primaryKey(),
  token: text("token").notNull(),
  clientId: text("client_id")
    .notNull()
    .references(() => oauthClient.clientId, { onDelete: "cascade" }),
  sessionId: text("session_id").references(() => session.id, {
    onDelete: "set null",
  }),
  userId: text("user_id")
    .notNull()
    .references(() => user.id, { onDelete: "cascade" }),
  referenceId: text("reference_id"),
  expiresAt: timestamp("expires_at"),
  createdAt: timestamp("created_at"),
  revoked: timestamp("revoked"),
  scopes: text("scopes").array().notNull(),
});

export const oauthAccessToken = pgTable("oauth_access_token", {
  id: text("id").primaryKey(),
  token: text("token").unique(),
  clientId: text("client_id")
    .notNull()
    .references(() => oauthClient.clientId, { onDelete: "cascade" }),
  sessionId: text("session_id").references(() => session.id, {
    onDelete: "set null",
  }),
  userId: text("user_id").references(() => user.id, { onDelete: "cascade" }),
  referenceId: text("reference_id"),
  refreshId: text("refresh_id").references(() => oauthRefreshToken.id, {
    onDelete: "cascade",
  }),
  expiresAt: timestamp("expires_at"),
  createdAt: timestamp("created_at"),
  scopes: text("scopes").array().notNull(),
});

export const oauthConsent = pgTable("oauth_consent", {
  id: text("id").primaryKey(),
  clientId: text("client_id")
    .notNull()
    .references(() => oauthClient.clientId, { onDelete: "cascade" }),
  userId: text("user_id").references(() => user.id, { onDelete: "cascade" }),
  referenceId: text("reference_id"),
  scopes: text("scopes").array().notNull(),
  createdAt: timestamp("created_at"),
  updatedAt: timestamp("updated_at"),
});
```

Include them in the exported schema:

```typescript
export const authSchema = {
  user,
  session,
  account,
  verification,
  jwks,
  oauthClient,
  oauthRefreshToken,
  oauthAccessToken,
  oauthConsent,
};
```

Generate and run the migration:

```bash
bun run db:generate
bun run db:migrate
```

### Phase 2: Configure OAuth Provider Plugin

**2.1 Add the plugin to BetterAuth**

```typescript
import { oauthProvider } from "@better-auth/oauth-provider";

export const auth = betterAuth({
  // ... existing config ...

  plugins: [
    // ... existing plugins (admin, username, bearer, jwt) ...
    oauthProvider({
      // Login page URL — where unauthenticated users are sent
      loginPage: "/oauth/login",
      // Consent page — required by plugin but first-party clients skip it
      consentPage: "/oauth/consent",
    }),
  ],
});
```

**IMPORTANT:** The `loginPage` and `consentPage` are relative to your API's base
URL. You must create routes to serve these pages (Phase 3). For first-party
clients with `skipConsent: true`, the consent page is never shown but must still
be configured.

**2.2 Seed OAuth clients on startup**

Create `src/features/auth/oauth-clients.ts`:

```typescript
import { db } from "@core/db";
import { oauthClient } from "./db";
import { eq } from "drizzle-orm";

// Must match the callback server port range in the desktop app
const LOOPBACK_HOST = "127.0.0.1";
const CALLBACK_PORT_START = 8789;
const CALLBACK_PORT_END = 8799;

function buildLoopbackRedirectUris(): string[] {
  const uris: string[] = [];
  for (let port = CALLBACK_PORT_START; port <= CALLBACK_PORT_END; port++) {
    uris.push(`http://${LOOPBACK_HOST}:${port}/callback`);
  }
  return uris;
}

const FIRST_PARTY_CLIENTS = [
  {
    clientId: "my-app-desktop-dev",
    name: "My App Desktop (Development)",
    redirectUris: buildLoopbackRedirectUris(),
  },
  {
    clientId: "my-app-desktop",
    name: "My App Desktop",
    redirectUris: buildLoopbackRedirectUris(),
  },
];

/**
 * Ensure all first-party OAuth clients are registered.
 * Inserts directly into the database with specific clientIds
 * (Better Auth's dynamic registration generates random IDs).
 * Safe to call on every startup — updates existing clients.
 */
export async function seedOAuthClients(): Promise<void> {
  for (const client of FIRST_PARTY_CLIENTS) {
    const existing = await db
      .select({ id: oauthClient.id })
      .from(oauthClient)
      .where(eq(oauthClient.clientId, client.clientId))
      .limit(1);

    const clientData = {
      name: client.name,
      redirectUris: client.redirectUris,
      public: true, // No client secret — native apps can't keep secrets
      skipConsent: true, // First-party: no consent screen
      grantTypes: ["authorization_code", "refresh_token"],
      responseTypes: ["code"],
      scopes: ["openid", "profile", "email", "offline_access"],
      tokenEndpointAuthMethod: "none", // Public client
      updatedAt: new Date(),
    };

    if (existing.length > 0) {
      await db
        .update(oauthClient)
        .set(clientData)
        .where(eq(oauthClient.clientId, client.clientId));
      continue;
    }

    await db.insert(oauthClient).values({
      id: crypto.randomUUID(),
      clientId: client.clientId,
      ...clientData,
      createdAt: new Date(),
    });
  }
}
```

**CRITICAL:** Seed clients **before** the server starts listening. The authorize
endpoint must be able to find the client immediately.

```typescript
// src/index.ts
await seedOAuthClients(); // Before .listen()

const app = new Elysia()
  // ... middleware, routes ...
  .listen({ hostname: "0.0.0.0", port: env.BUN_PORT });
```

### Phase 3: Serve the Login Page

The login page is a standalone HTML page served by the API. When the OAuth
authorize endpoint finds no active session, it redirects the browser here. The
page collects credentials, calls BetterAuth's sign-in endpoint to establish a
session cookie, then redirects back to the authorize endpoint with the original
OAuth params.

```typescript
// src/routes/oauth/index.ts
import { Elysia } from "elysia";
import { eq } from "drizzle-orm";
import { requireAuth, formatError } from "@core/http";
import { db } from "@core/db";
import {
  session,
  oauthAccessToken,
  oauthRefreshToken,
} from "@features/auth/db";

const loginPageHtml = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Sign In</title>
  <!-- Style as appropriate for your app -->
</head>
<body>
  <form id="loginForm">
    <input type="email" id="email" required />
    <input type="password" id="password" required />
    <button type="submit">Sign In</button>
    <div id="errorMsg"></div>
  </form>
  <script>
    const params = new URLSearchParams(window.location.search);
    const oauthParams = {
      client_id: params.get('client_id'),
      redirect_uri: params.get('redirect_uri'),
      state: params.get('state'),
      code_challenge: params.get('code_challenge'),
      code_challenge_method: params.get('code_challenge_method'),
      response_type: params.get('response_type'),
      scope: params.get('scope'),
    };

    document.getElementById('loginForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      try {
        // 1. Sign in — sets session cookie
        const res = await fetch('/api/auth/sign-in/email', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            email: document.getElementById('email').value,
            password: document.getElementById('password').value,
          }),
          credentials: 'include',
        });
        if (!res.ok) throw new Error('Invalid credentials');

        // 2. Redirect to authorize with original OAuth params
        const authorizeUrl = new URL('/api/auth/oauth2/authorize', location.origin);
        for (const [key, value] of Object.entries(oauthParams)) {
          if (value) authorizeUrl.searchParams.set(key, value);
        }
        window.location.href = authorizeUrl.toString();
      } catch (err) {
        document.getElementById('errorMsg').textContent = err.message;
      }
    });
  </script>
</body>
</html>`;

export const oauthRoutes = new Elysia({ prefix: "/oauth" })
  .get("/login", ({ set }) => {
    set.headers["Content-Type"] = "text/html; charset=utf-8";
    return loginPageHtml;
  })
  // Session/token revocation endpoint (for sign-out)
  .use(requireAuth)
  .post("/revoke-all-sessions", async ({ user, set }) => {
    try {
      await Promise.all([
        db.delete(session).where(eq(session.userId, user!.id)),
        db
          .delete(oauthAccessToken)
          .where(eq(oauthAccessToken.userId, user!.id)),
        db
          .delete(oauthRefreshToken)
          .where(eq(oauthRefreshToken.userId, user!.id)),
      ]);
      return { success: true };
    } catch (err) {
      const { body, status } = formatError(err);
      set.status = status;
      return body;
    }
  });
```

**Why the two-step login flow?** Better Auth's authorize endpoint checks for an
active session cookie. If none exists, it 302s to `loginPage`. The login page
signs in (establishing the cookie), then redirects back to authorize which now
has a valid session and can issue the authorization code.

Wire the routes into `src/index.ts`:

```typescript
import { oauthRoutes } from "./routes/oauth";

const app = new Elysia()
  // ...
  .use(oauthRoutes);
// ...
```

### Phase 4: Update Session Middleware for OAuth Tokens

The base recipe's session middleware only checks BetterAuth session cookies.
OAuth clients send `Authorization: Bearer {access_token}` instead. Update the
middleware to try both:

```typescript
// src/core/http/session.ts
import { Elysia } from "elysia";
import { auth, type User } from "@features/auth";
import { db } from "@core/db";
import { user as userTable } from "@features/auth/db";
import { eq } from "drizzle-orm";

/**
 * Resolve a user from an OAuth access token by calling
 * Better Auth's userinfo endpoint internally.
 */
async function resolveOAuthUser(request: Request): Promise<User | null> {
  const authHeader = request.headers.get("authorization");
  if (!authHeader?.startsWith("Bearer ")) return null;

  try {
    const userinfoRequest = new Request(
      new URL("/api/auth/oauth2/userinfo", "http://localhost"),
      { headers: { authorization: authHeader } }
    );

    const response = await auth.handler(userinfoRequest);
    if (!response.ok) return null;

    const userInfo = (await response.json()) as { sub?: string };
    if (!userInfo.sub) return null;

    const users = await db
      .select()
      .from(userTable)
      .where(eq(userTable.id, userInfo.sub))
      .limit(1);

    return users.length ? (users[0] as unknown as User) : null;
  } catch {
    return null;
  }
}

export const sessionMiddleware = new Elysia({ name: "session" }).derive(
  { as: "global" },
  async ({ request }) => {
    // Try BetterAuth session first (cookies)
    const session = await auth.api.getSession({ headers: request.headers });
    if (session?.user) {
      return { user: session.user as User, session: session.session };
    }

    // Fall back to OAuth access token (Bearer header)
    const oauthUser = await resolveOAuthUser(request);
    return { user: oauthUser, session: null };
  }
);
```

**Why call `auth.handler` internally?** Better Auth hashes OAuth tokens before
storage. You cannot look up a raw token with a database query. Routing through
the handler uses Better Auth's internal token validation, which handles the
hashing. The `http://localhost` base URL is a dummy — only the path and headers
matter since it's processed in-process.

**Validate:** After this change, existing session-based auth (admin dashboard,
browser) still works AND Bearer token auth from native clients works. Both
resolve to the same `User` type in the request context.

### Phase 5: PowerSync JWT Integration (Optional)

If you use PowerSync for local-first sync, clients need JWTs signed with your
JWKS keys. PowerSync verifies these JWTs against your `/api/auth/jwks` endpoint
(provided automatically by Better Auth's `jwt()` plugin).

**5.1 Create the token endpoint**

```typescript
// src/routes/sync/powersync.ts (token portion)
import { Elysia } from "elysia";
import { desc } from "drizzle-orm";
import { requireAuth, APIError, formatError } from "@core/http";
import { db } from "@core/db";
import { jwks } from "@features/auth/db";
import { env } from "@core/config";
import { symmetricDecrypt } from "better-auth/crypto";
import { SignJWT, importJWK } from "jose";

export const powersyncRoutes = new Elysia({ prefix: "/powersync" })
  .use(requireAuth)
  .get("/token", async ({ user, set }) => {
    try {
      // 1. Read the latest JWKS key from the database
      const keys = await db
        .select()
        .from(jwks)
        .orderBy(desc(jwks.createdAt))
        .limit(1);

      if (!keys.length) {
        throw APIError.unavailable("No signing keys available");
      }

      const key = keys[0];

      // 2. Decrypt the private key
      //    Better Auth encrypts JWKS private keys with BETTER_AUTH_SECRET
      const decryptedPrivateKey = await symmetricDecrypt({
        key: env.BETTER_AUTH_SECRET,
        data: JSON.parse(key.privateKey),
      });

      // 3. Import for signing
      const alg = "RS256";
      const privateKey = await importJWK(JSON.parse(decryptedPrivateKey), alg);

      // 4. Sign the JWT
      const baseURL = env.BETTER_AUTH_URL;
      const now = Math.floor(Date.now() / 1000);
      const token = await new SignJWT({ sub: user!.id })
        .setProtectedHeader({ alg, kid: key.id })
        .setIssuedAt(now)
        .setExpirationTime(now + 15 * 60) // 15 minutes
        .setIssuer(baseURL)
        .setAudience(baseURL)
        .setSubject(user!.id)
        .sign(privateKey);

      return { token };
    } catch (err) {
      const { body, status } = formatError(err);
      set.status = status;
      return body;
    }
  });
```

**CRITICAL: `symmetricDecrypt` from `better-auth/crypto`.** Better Auth stores
JWKS private keys encrypted with `BETTER_AUTH_SECRET`. You must decrypt them
before use. The decrypted value is a JSON string containing a JWK — parse it and
pass to `importJWK` from `jose`.

**5.2 Configure PowerSync to verify against your JWKS**

In your PowerSync dashboard or `powersync.yaml`, set the JWKS URL to your
BetterAuth JWKS endpoint:

```yaml
# powersync.yaml
jwks_uri: https://your-api.com/api/auth/jwks
```

The `kid` in the JWT header must match a key in the JWKS response. Better Auth
handles this automatically via the `jwt()` plugin.

**5.3 PowerSync sync rules use the `sub` claim**

```yaml
bucket_definitions:
  user_data:
    parameters: SELECT token_parameters.user_id as user_id
    data:
      - SELECT * FROM documents WHERE owner_id = bucket.user_id
```

PowerSync extracts `user_id` from the JWT's `sub` claim via
`token_parameters.user_id`.

### Phase 6: Desktop Client Implementation

This phase covers the native client side. The examples use Electron but the
pattern applies to any desktop framework.

**6.1 PKCE flow service**

Implement the standard OAuth 2.1 PKCE helpers:

```typescript
// oauth-flow.ts (renderer/client side)

function generateRandomString(length: number): string {
  const array = new Uint8Array(length);
  crypto.getRandomValues(array);
  return Array.from(array, (byte) => byte.toString(36).padStart(2, "0"))
    .join("")
    .slice(0, length);
}

export function generateCodeVerifier(): string {
  return generateRandomString(64);
}

export async function generateCodeChallenge(verifier: string): Promise<string> {
  const data = new TextEncoder().encode(verifier);
  const hash = await crypto.subtle.digest("SHA-256", data);
  return btoa(String.fromCharCode(...new Uint8Array(hash)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

export function generateState(): string {
  return generateRandomString(32);
}

export function buildAuthorizationUrl(params: {
  clientId: string;
  redirectUri: string;
  codeChallenge: string;
  state: string;
  scope?: string;
}): string {
  const url = new URL(`${API_BASE_URL}/api/auth/oauth2/authorize`);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", params.clientId);
  url.searchParams.set("redirect_uri", params.redirectUri);
  url.searchParams.set("code_challenge", params.codeChallenge);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("state", params.state);
  url.searchParams.set(
    "scope",
    params.scope ?? "openid profile email offline_access"
  );
  // Force re-authentication to support account switching
  url.searchParams.set("prompt", "login");
  return url.toString();
}

export async function exchangeCodeForTokens(params: {
  code: string;
  codeVerifier: string;
  clientId: string;
  redirectUri: string;
}): Promise<{
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}> {
  const response = await fetch(`${API_BASE_URL}/api/auth/oauth2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code: params.code,
      code_verifier: params.codeVerifier,
      client_id: params.clientId,
      redirect_uri: params.redirectUri,
    }),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Token exchange failed (${response.status}): ${body}`);
  }

  const data = await response.json();
  return {
    accessToken: data.access_token,
    refreshToken: data.refresh_token,
    expiresIn: data.expires_in,
  };
}

export async function refreshTokenGrant(params: {
  refreshToken: string;
  clientId: string;
}): Promise<{
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}> {
  const response = await fetch(`${API_BASE_URL}/api/auth/oauth2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: params.refreshToken,
      client_id: params.clientId,
    }),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Token refresh failed (${response.status}): ${body}`);
  }

  const data = await response.json();
  return {
    accessToken: data.access_token,
    refreshToken: data.refresh_token,
    expiresIn: data.expires_in,
  };
}

export async function fetchOAuthUserInfo(accessToken: string): Promise<{
  sub: string;
  name?: string;
  email?: string;
  email_verified?: boolean;
  picture?: string;
}> {
  const response = await fetch(`${API_BASE_URL}/api/auth/oauth2/userinfo`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!response.ok) {
    throw new Error(`Userinfo failed (${response.status})`);
  }
  return response.json();
}
```

**6.2 Loopback callback server (Electron main process)**

```typescript
// oauth-callback-server.ts (main process)
import { createServer, type Server } from "http";

const CALLBACK_PORT_START = 8789;
const CALLBACK_PORT_END = 8799;
const LOOPBACK_HOST = "127.0.0.1";

let server: Server | null = null;
let activePort: number | null = null;

function tryListen(srv: Server, port: number): Promise<number> {
  return new Promise((resolve, reject) => {
    const onError = (err: NodeJS.ErrnoException) => {
      srv.removeListener("listening", onListening);
      reject(err);
    };
    const onListening = () => {
      srv.removeListener("error", onError);
      resolve(port);
    };
    srv.once("error", onError);
    srv.once("listening", onListening);
    srv.listen(port, LOOPBACK_HOST);
  });
}

export async function startCallbackServer(): Promise<{
  code: string;
  state: string;
}> {
  if (server) {
    server.close();
    server = null;
    activePort = null;
  }

  let settled = false;

  return new Promise((resolve, reject) => {
    const safeResolve = (value: { code: string; state: string }) => {
      if (!settled) {
        settled = true;
        resolve(value);
      }
    };
    const safeReject = (err: Error) => {
      if (!settled) {
        settled = true;
        reject(err);
      }
    };

    const srv = createServer((req, res) => {
      // Use static base URL — activePort may be null if a late request
      // (favicon) arrives after stopCallbackServer()
      const url = new URL(
        req.url ?? "/",
        `http://${LOOPBACK_HOST}:${CALLBACK_PORT_START}`
      );

      if (url.pathname === "/callback") {
        const code = url.searchParams.get("code");
        const state = url.searchParams.get("state");
        const error = url.searchParams.get("error");

        res.writeHead(200, { "Content-Type": "text/html" });

        if (error) {
          res.end("<html><body><h2>Authentication Failed</h2></body></html>");
          stopCallbackServer();
          safeReject(new Error(`OAuth error: ${error}`));
          return;
        }

        if (code && state) {
          res.end(
            "<html><body><h2>Success!</h2><p>You can close this window.</p><script>window.close();</script></body></html>"
          );
          stopCallbackServer();
          safeResolve({ code, state });
          return;
        }

        res.end("<html><body><h2>Invalid Callback</h2></body></html>");
        stopCallbackServer();
        safeReject(new Error("Missing code or state"));
        return;
      }

      res.writeHead(404);
      res.end("Not Found");
    });

    // Try ports in the pool
    (async () => {
      for (let port = CALLBACK_PORT_START; port <= CALLBACK_PORT_END; port++) {
        try {
          const boundPort = await tryListen(srv, port);
          server = srv;
          activePort = boundPort;
          return; // Wait for callback
        } catch (err: unknown) {
          const nodeErr = err as NodeJS.ErrnoException;
          if (nodeErr.code === "EADDRINUSE") continue;
          safeReject(new Error(`Callback server error: ${nodeErr.message}`));
          return;
        }
      }
      safeReject(
        new Error(
          `All ports ${CALLBACK_PORT_START}-${CALLBACK_PORT_END} in use`
        )
      );
    })();

    // Timeout with settled guard to prevent stale timeouts from
    // killing a subsequent flow's server
    setTimeout(
      () => {
        if (!settled && server) {
          stopCallbackServer();
          safeReject(new Error("OAuth callback timed out"));
        }
      },
      5 * 60 * 1000
    );
  });
}

export function stopCallbackServer(): void {
  if (server) {
    server.close();
    server = null;
    activePort = null;
  }
}

export function getCallbackRedirectUri(): string {
  const port = activePort ?? CALLBACK_PORT_START;
  return `http://${LOOPBACK_HOST}:${port}/callback`;
}
```

**6.3 IPC bridge (Electron)**

The main process opens the browser and waits for the callback. The renderer
initiates the flow. An IPC bridge connects them:

```typescript
// oauth-ipc.ts (main process)
import { ipcMain, shell, BrowserWindow } from "electron";
import {
  startCallbackServer,
  stopCallbackServer,
  getCallbackRedirectUri,
} from "./oauth-callback-server";

const OAUTH_CLIENT_ID =
  process.env.NODE_ENV === "development"
    ? "my-app-desktop-dev"
    : "my-app-desktop";

export function setupOAuthIPC(getMainWindow: () => BrowserWindow | null): void {
  ipcMain.handle("oauth:get-config", () => ({
    clientId: OAUTH_CLIENT_ID,
    redirectUri: getCallbackRedirectUri(),
  }));

  ipcMain.handle(
    "oauth:start-flow",
    async (
      _,
      authorizationUrl: string
    ): Promise<{ code: string; state: string; redirectUri: string }> => {
      // Start callback server to determine actual port
      const callbackPromise = startCallbackServer();
      const actualRedirectUri = getCallbackRedirectUri();

      // Patch the redirect_uri to match the actual port
      const url = new URL(authorizationUrl);
      url.searchParams.set("redirect_uri", actualRedirectUri);

      try {
        await shell.openExternal(url.toString());
      } catch (err) {
        stopCallbackServer();
        throw err;
      }

      const result = await callbackPromise;

      // Focus the app window
      const mainWindow = getMainWindow();
      if (mainWindow) {
        if (mainWindow.isMinimized()) mainWindow.restore();
        mainWindow.focus();
      }

      return { ...result, redirectUri: actualRedirectUri };
    }
  );
}
```

**Why patch `redirect_uri` after starting the server?** The renderer builds the
authorization URL with a default redirect URI, but the callback server may bind
to a different port if the default is busy. The main process patches the URL
after the server binds to ensure the redirect URI matches the actual port.

**6.4 Sign-in flow (renderer)**

```typescript
async function signIn() {
  const config = await window.oauth.getConfig();
  const codeVerifier = generateCodeVerifier();
  const codeChallenge = await generateCodeChallenge(codeVerifier);
  const state = generateState();

  const authUrl = buildAuthorizationUrl({
    clientId: config.clientId,
    redirectUri: config.redirectUri,
    codeChallenge,
    state,
  });

  // Opens browser, waits for callback, returns code + actual redirectUri
  const result = await window.oauth.startFlow(authUrl);

  // Verify state matches
  if (result.state !== state) {
    throw new Error("OAuth state mismatch — possible CSRF attack");
  }

  // Exchange code for tokens (use result.redirectUri, not config.redirectUri)
  const tokens = await exchangeCodeForTokens({
    code: result.code,
    codeVerifier,
    clientId: config.clientId,
    redirectUri: result.redirectUri,
  });

  // Store tokens securely (e.g., Electron safeStorage, keychain)
  await storeTokens(tokens.accessToken, tokens.refreshToken);

  // Fetch user info
  const userInfo = await fetchOAuthUserInfo(tokens.accessToken);
  // Update UI with user info...
}
```

**6.5 Token refresh**

When the access token expires (401 response from API), use the refresh token:

```typescript
async function refreshSession(): Promise<boolean> {
  const refreshToken = await getRefreshToken();
  if (!refreshToken) return false;

  try {
    const config = await window.oauth.getConfig();
    const tokens = await refreshTokenGrant({
      refreshToken,
      clientId: config.clientId,
    });

    await storeTokens(tokens.accessToken, tokens.refreshToken);

    // Optionally fetch updated user info
    const userInfo = await fetchOAuthUserInfo(tokens.accessToken);
    // Update cached user...

    return true;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (message.includes("Token refresh failed")) {
      // Server rejected the refresh token — force re-auth
      await handleAuthExpired();
    }
    // Network errors: keep cached tokens, retry later
    return false;
  }
}
```

**6.6 Sign-out with server revocation**

```typescript
async function signOut() {
  try {
    const accessToken = await getAccessToken();
    if (accessToken) {
      const response = await fetch(
        `${API_BASE_URL}/oauth/revoke-all-sessions`,
        {
          method: "POST",
          headers: { Authorization: `Bearer ${accessToken}` },
        }
      );
      if (!response.ok) {
        // Warn user but continue with local sign-out
        console.warn("Server revocation failed:", response.status);
      }
    }
  } catch {
    // Network error — continue with local sign-out
  }

  // Always clear local tokens regardless of server response
  await clearTokens();
  // Reset UI state...
}
```

## Critical Integration Details

### Better Auth Logs 302s as ERROR

During normal OAuth flow, Better Auth logs 302 redirects as ERROR-level entries.
This is expected behavior — the authorize endpoint redirecting to the login page
and the login page redirecting back are normal 302s. Don't be alarmed by these
logs.

### Public Clients: `tokenEndpointAuthMethod: 'none'`

Native apps are "public clients" per OAuth spec — they cannot securely store a
client secret. Set `public: true` and `tokenEndpointAuthMethod: 'none'` on the
client registration. PKCE provides the security instead of a client secret.

### `offline_access` Scope for Refresh Tokens

Include `offline_access` in the requested scopes to receive refresh tokens.
Without it, you only get an access token with no way to refresh.

### `prompt=login` for Forced Re-Authentication

Set `prompt=login` on the authorization URL to force the user to sign in every
time, even if they have an active browser session. This supports account
switching and prevents session reuse on shared machines after sign-out.

### Static Base URL in Callback Server

When constructing `new URL(req.url, base)` in the callback server, use a static
base URL like `http://127.0.0.1:8789` instead of the dynamic active port. After
`stopCallbackServer()` sets the port to null, late requests (favicon, etc.)
would cause `new URL(req.url, 'http://127.0.0.1:null')` which throws
`TypeError: Invalid URL`.

### Settled Guard on Timeout

The callback server's timeout handler must check `!settled` before calling
`stopCallbackServer()`. Without this guard, a stale timeout from flow A could
kill the server that was started for a subsequent flow B.

### `redirect_uri` Must Match Exactly

The `redirect_uri` in the token exchange request must exactly match the one used
in the authorization request (including port). Since the callback server may
bind to a fallback port, the main process returns the actual `redirectUri` to
the renderer for use in the token exchange.

## Gotchas & Important Notes

- **Schema must be manually maintained.** The OAuth Provider plugin does NOT
  auto-create tables. Add the four OAuth tables to your Drizzle schema and run
  migrations. If columns are missing, Better Auth silently fails.

- **`seedOAuthClients` must run before `.listen()`.** If a client tries to
  authorize before the client is seeded, the authorize endpoint returns an
  error. `await seedOAuthClients()` synchronously before starting the server.

- **Better Auth hashes tokens.** You cannot query `oauth_access_token` or
  `oauth_refresh_token` by raw token value. Always validate tokens through
  Better Auth's handler/API, not with direct database queries.

- **`symmetricDecrypt` import path matters.** Import from `better-auth/crypto`,
  not from `better-auth`. The crypto utilities are a separate export.

- **JWKS private key is double-encoded.** The `privateKey` column contains a
  JSON string of the encrypted data. You must `JSON.parse` it before passing to
  `symmetricDecrypt`, then `JSON.parse` the result again before `importJWK`.

- **Port range must match on client and server.** The loopback port range in the
  callback server must match the redirect URIs registered for the OAuth client.
  If the client tries a port that isn't registered, the authorize endpoint
  rejects the redirect URI.

- **Don't use `localhost` anywhere in redirect URIs.** Use `127.0.0.1`
  consistently in both client redirect URIs and server registrations. Mixing
  `localhost` and `127.0.0.1` causes redirect URI mismatch errors.

## External Documentation

- **@better-auth/oauth-provider:**
  https://better-auth.com/docs/plugins/oauth-provider
- **RFC 7636 (PKCE):** https://tools.ietf.org/html/rfc7636
- **RFC 8252 (OAuth for Native Apps):** https://tools.ietf.org/html/rfc8252
- **jose (JWT signing):** https://github.com/panva/jose
- **PowerSync Auth:**
  https://docs.powersync.com/usage/installation/authentication-setup
