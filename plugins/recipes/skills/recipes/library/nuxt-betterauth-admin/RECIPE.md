# Nuxt 4 + BetterAuth Admin Dashboard Recipe

## Purpose

Set up a Nuxt 4 admin dashboard that authenticates against a separate BetterAuth

- Elysia API server. This recipe captures the integration glue between Nuxt's
  SSR architecture, BetterAuth's cookie-based session model, and Elysia's route
  guards -- the parts that aren't documented in any single library's docs and
  that you'd discover through trial and error.

The core challenge: BetterAuth uses HTTPOnly cookies for sessions, but the Nuxt
app and API run on different ports. Without a specific proxy and middleware
setup, authentication silently fails.

## UI Reference

See `references/admin-dashboard-mockup.html` for an interactive prototype of the
admin dashboard and user management UI. Open in a browser to explore the
dashboard view, users list with detail sidebar, role change flow, and ban/unban
confirmation patterns. Use this as the visual starting point and adapt to the
target design system.

## When to Use

- Adding a web admin dashboard to an existing BetterAuth + Elysia API
- Building a backoffice for user management, role assignment, or system
  configuration
- Setting up a Nuxt 4 app that needs to authenticate against a separate API
  server via cookies
- Adding role-based access control (admin vs regular user) to a BetterAuth
  system

## Technology Stack

| Layer         | Technology               | Version |
| ------------- | ------------------------ | ------- |
| Frontend      | Nuxt 4 (Vue 3)           | 4.2+    |
| Auth Client   | BetterAuth (Vue client)  | 1.4+    |
| UI Components | shadcn-vue + Tailwind v4 | --      |
| API Server    | Elysia (Bun)             | --      |
| Auth Server   | BetterAuth (server)      | 1.4+    |
| Database      | PostgreSQL + Drizzle ORM | --      |

## Architecture Overview

### The Cookie Proxy Problem

BetterAuth uses HTTPOnly cookies for session management. When the Nuxt app
(port 3000) makes requests to the Elysia API (port 3011), they are cross-origin.
Browsers do not send cookies cross-origin by default, and even with
`credentials: 'include'`, the `Set-Cookie` response header is blocked because
the origins differ.

**The solution:** Nuxt's `routeRules` proxy. The Nuxt server proxies all
`/api/**` requests to the Elysia backend. From the browser's perspective, it's
talking to the same origin (port 3000), so cookies flow freely.

```
BROWSER (port 3000)
  │
  │  POST /api/auth/sign-in/email  (same origin, cookies attached)
  │  GET  /api/admin/users         (same origin, cookies attached)
  │
  ▼
NUXT SERVER (port 3000)
  │
  │  routeRules: { '/api/**': { proxy: 'http://localhost:3011/api/**' } }
  │  (forwards request with all headers including cookies)
  │
  ▼
ELYSIA API (port 3011)
  │
  │  sessionMiddleware → auth.api.getSession({ headers: request.headers })
  │  requireAdmin guard → checks user.role === 'admin'
  │
  ▼
  Response flows back: Elysia → Nuxt proxy → Browser
  (Set-Cookie headers are preserved because same origin)
```

### Why Not Direct API Calls?

You might think: "just set CORS headers and use `credentials: 'include'`." This
fails because:

1. `Set-Cookie` with `SameSite=Lax` (BetterAuth's default) is blocked
   cross-origin
2. Even with `SameSite=None; Secure`, you need HTTPS in development
3. The Nuxt proxy approach is simpler, works in dev without HTTPS, and
   eliminates all CORS issues

### SSR Limitation

BetterAuth's Vue client (`createAuthClient`) requires browser context -- it
reads cookies from `document.cookie` and uses `fetch` with cookie credentials.
During Nuxt's server-side rendering phase, there is no browser context.

**Result:** Auth checks must be skipped during SSR and performed client-side
after hydration. This means a brief flash of loading state on protected pages,
but it's the only reliable approach with BetterAuth's cookie model.

### Security Model

```
NUXT ADMIN (frontend, UX-level protection)
  │
  │  auth middleware     → redirects unauthenticated users to /sign-in
  │  admin layout guard  → redirects non-admin users to /
  │  (client-side only, for UX -- NOT security)
  │
ELYSIA API (backend, actual security)
  │
  │  sessionMiddleware   → extracts user from BetterAuth session cookies
  │  requireAdmin guard  → returns 401/403 if not authenticated/admin
  │  (server-side, enforced on every request -- THIS is the security layer)
```

The Nuxt-side guards are purely UX. They prevent showing admin UI to
unauthorized users but cannot prevent API access. The Elysia guards are the
actual security boundary.

## Implementation Process

### Phase 1: BetterAuth Admin Plugin (Server Side)

The `admin()` plugin must be added to the BetterAuth server configuration.
Without it, the `user.role` field is not managed by BetterAuth and admin
endpoints don't exist.

**1.1 Add the admin plugin to BetterAuth**

In your Elysia API's BetterAuth adapter:

```typescript
import { betterAuth } from "better-auth";
import { admin } from "better-auth/plugins";
import { username } from "better-auth/plugins";

export const auth = betterAuth({
  // ... database, email config, etc.
  plugins: [
    admin(), // Enables user.role field and admin management endpoints
    username(), // If your schema uses usernames
    // ... other plugins
  ],
});
```

**What `admin()` provides:**

- Adds `role` field to the user model (defaults to `'user'`)
- Adds `/api/auth/admin/*` endpoints for user management
- Provides `adminClient()` for the frontend to call these endpoints

**What `admin()` does NOT do:**

- Does NOT auto-protect any routes. You must add guards manually.
- Does NOT create an admin user. You must promote a user to admin via database
  or a setup script.

**1.2 Create an admin promotion script or Docker target**

You need a way to make the first user an admin. Common approaches:

```typescript
// scripts/promote-admin.ts
import { db } from "./db";
import { user } from "./schema";
import { eq } from "drizzle-orm";

const email = process.env.ADMIN_EMAIL;
if (!email) throw new Error("ADMIN_EMAIL required");

await db.update(user).set({ role: "admin" }).where(eq(user.email, email));
```

**Validate:** After running the promotion script, query the user table and
confirm the target user has `role = 'admin'`.

### Phase 2: Elysia Route Guards

Create reusable middleware for protecting admin API routes.

**2.1 Session middleware**

This middleware extracts the BetterAuth session from request cookies and makes
`user` and `session` available to all downstream handlers:

```typescript
// src/core/http/session.ts
import { Elysia } from "elysia";
import { auth } from "@features/auth";

export const sessionMiddleware = new Elysia({ name: "session" }).derive(
  { as: "global" },
  async ({ request }) => {
    const session = await auth.api.getSession({
      headers: request.headers,
    });

    return {
      user: session?.user ?? null,
      session: session?.session ?? null,
    };
  }
);
```

**Critical detail:** `auth.api.getSession({ headers: request.headers })` reads
the session cookie from the incoming request headers. The Nuxt proxy forwards
these headers transparently, so the cookie arrives here as if the browser had
called Elysia directly.

**2.2 Admin guard**

```typescript
// src/core/http/guards.ts
import { Elysia } from "elysia";
import { sessionMiddleware } from "./session";

export const requireAdmin = new Elysia({ name: "guard:admin" })
  .use(sessionMiddleware)
  .onBeforeHandle({ as: "scoped" }, ({ user, set }) => {
    if (!user) {
      set.status = 401;
      return { error: { message: "Authentication required" } };
    }
    if (user.role !== "admin") {
      set.status = 403;
      return { error: { message: "Admin access required" } };
    }
    return undefined;
  });
```

**Why `{ as: 'scoped' }`:** This makes the guard apply only to the Elysia
instance it's `.use()`d on, not globally. Each route group that needs admin
protection explicitly opts in.

**2.3 Apply guards to admin routes**

```typescript
// src/routes/admin/users.ts
import { Elysia } from "elysia";
import { requireAdmin } from "@core/http";

export const adminUsersRoutes = new Elysia({ prefix: "/admin/users" })
  .use(requireAdmin) // All routes in this group require admin
  .get("/", async () => {
    // List all users from database
    const users = await db.select().from(userTable);
    return { users, total: users.length };
  })
  .patch(
    "/:id/role",
    async ({ params, body }) => {
      // Update user role
      await db
        .update(userTable)
        .set({ role: body.role })
        .where(eq(userTable.id, params.id));
      return { success: true };
    },
    {
      body: t.Object({ role: t.String() }),
    }
  );
```

**Pattern:** Every admin route file follows the same structure: create an Elysia
instance with a prefix, `.use(requireAdmin)` at the top, then define routes.
This ensures no admin route accidentally ships without protection.

**Validate:** Call an admin endpoint without a session cookie -- should get 401.
Call with a non-admin session -- should get 403. Call with an admin session --
should get data.

### Phase 3: Nuxt Project Setup

**3.1 Create the Nuxt 4 app**

```bash
npx nuxi@latest init admin
cd admin
```

**3.2 Install dependencies**

```bash
# Auth client
pnpm add better-auth

# UI (optional, but recommended)
pnpm add shadcn-nuxt
npx shadcn-vue@latest init
```

**3.3 Configure nuxt.config.ts with API proxy**

This is the most critical configuration in the entire recipe:

```typescript
const apiUrl = process.env.NUXT_PUBLIC_API_URL || "http://localhost:3011";

export default defineNuxtConfig({
  runtimeConfig: {
    public: {
      apiUrl: "/",
    },
  },
  // THIS IS THE KEY: Proxy all /api/* requests to the Elysia backend
  routeRules: {
    "/api/**": {
      proxy: `${apiUrl}/api/**`,
    },
  },
});
```

**Why `routeRules` and not `nitro.devProxy`:** `routeRules` works in both
development AND production. `nitro.devProxy` only works during `nuxt dev`. Since
the admin dashboard is a real deployed app (not just a dev tool), `routeRules`
is the correct choice.

**Why the API URL is read from an env var:** In development, the API is at
`localhost:3011`. In production, it might be at a different host. The env var
allows deployment-time configuration without rebuilding.

**Validate:** Start both the Nuxt app and Elysia API. Navigate to
`http://localhost:3000/api/auth/ok` in the browser -- it should proxy to Elysia
and return a response.

### Phase 4: BetterAuth Client Plugin

**4.1 Create the auth client Nuxt plugin**

```typescript
// app/plugins/auth-client.ts
import { createAuthClient } from "better-auth/vue";
import { adminClient, usernameClient } from "better-auth/client/plugins";

export default defineNuxtPlugin(() => {
  const auth = createAuthClient({
    // No baseURL needed -- requests go to /api/auth/* on the same origin,
    // which the routeRules proxy forwards to Elysia
    plugins: [adminClient(), usernameClient()],
  });

  return {
    provide: {
      auth,
    },
  };
});
```

**Why no `baseURL`:** BetterAuth's default base URL is `/api/auth` on the
current origin. Since the Nuxt proxy handles `/api/**`, this works
automatically. Setting an explicit `baseURL` to the Elysia server would bypass
the proxy and break cookie handling.

**Why `adminClient()`:** This plugin adds admin-specific methods to the auth
client (e.g., `$auth.admin.listUsers()`). Without it, you'd need to make raw
fetch calls to admin endpoints.

**Why `usernameClient()`:** Only needed if your BetterAuth server uses the
`username()` plugin. The client plugins must mirror the server plugins.

**4.2 Access the client throughout the app**

The plugin provides `$auth` via Nuxt's plugin injection:

```typescript
const { $auth } = useNuxtApp();

// Sign in
await $auth.signIn.email({ email, password });

// Get current session
const { data: session } = await $auth.getSession();

// Reactive session (Vue ref)
const session = $auth.useSession();

// Admin operations
const { users } = await $auth.admin.listUsers();
```

**Validate:** Open the Nuxt app, open DevTools Network tab, sign in. Verify that
the sign-in request goes to `/api/auth/sign-in/email` (same origin, port 3000),
and the response includes a `Set-Cookie` header.

### Phase 5: Auth Middleware (Client-Side Only)

**5.1 Create the auth middleware**

```typescript
// app/middleware/auth.ts
export default defineNuxtRouteMiddleware(async (to) => {
  // CRITICAL: Skip auth check on server
  // BetterAuth client needs browser context (cookies via document.cookie)
  // Server-side rendering has no access to browser cookies
  if (import.meta.server) {
    return;
  }

  const { $auth } = useNuxtApp();
  const { data: session } = await $auth.getSession();

  if (!session?.user) {
    return navigateTo({
      path: "/sign-in",
      query: { redirect: to.fullPath },
    });
  }
});
```

**Why `if (import.meta.server) return`:** During SSR, Nuxt executes middleware
on the server before sending HTML to the browser. BetterAuth's client reads
cookies from the browser, which doesn't exist during SSR. Without this guard,
every SSR request would incorrectly redirect to sign-in.

**The trade-off:** Users see a brief loading state while the client-side auth
check runs after hydration. This is unavoidable with BetterAuth's cookie-based
model in Nuxt SSR. The loading state is typically <200ms.

**5.2 Apply middleware to protected pages**

```typescript
// In any page that requires authentication:
definePageMeta({
  middleware: "auth",
});
```

**Validate:** Visit a protected page while signed out -- should redirect to
`/sign-in?redirect=/original-page`. Sign in -- should redirect back to the
original page.

### Phase 6: Admin Layout with Role Guard

> **UI reference:** The prototype in `references/admin-dashboard-mockup.html`
> shows the target layout — sidebar nav, dashboard stats, users table with
> detail sidebar, and action confirmation modals.

**6.1 Create the admin layout**

The admin layout adds a second layer of protection: role checking. While the
auth middleware checks "is the user logged in?", the admin layout checks "is the
user an admin?"

```vue
<!-- app/layouts/admin.vue -->
<script setup lang="ts">
const { $auth } = useNuxtApp();
const session = $auth.useSession();

watchEffect(() => {
  // Wait for session to load
  if (session.value?.isPending) return;

  const user = session.value?.data?.user;
  if (!user) {
    navigateTo("/sign-in");
    return;
  }
  if (user.role !== "admin") {
    navigateTo("/");
  }
});
</script>

<template>
  <div class="min-h-screen bg-background">
    <!-- Admin navigation -->
    <nav class="border-b bg-muted/30">
      <div class="container mx-auto px-4 flex gap-4 py-2">
        <NuxtLink to="/admin/users" active-class="font-medium">
          Users
        </NuxtLink>
        <!-- Add more admin nav links here -->
      </div>
    </nav>

    <main class="container mx-auto px-4 py-8">
      <!-- Show loading while session is being checked -->
      <div v-if="session.isPending" class="flex justify-center py-12">
        Loading...
      </div>
      <!-- Only render page content after session is confirmed -->
      <div v-show="!session.isPending">
        <slot />
      </div>
    </main>
  </div>
</template>
```

**Why `v-show` not `v-if` for the slot:** `v-show` renders the DOM but hides it
with CSS, so child components are created during hydration. `v-if` would delay
child component creation until the session check completes, causing a jarring
layout shift. With `v-show`, the transition is smoother.

**6.2 Apply the admin layout to admin pages**

```typescript
// app/pages/admin/users.vue
definePageMeta({
  layout: "admin",
});
```

**Note:** The admin layout includes its own auth check, so pages using the admin
layout don't also need the auth middleware. Using both is harmless but
redundant.

**Validate:** Sign in as a non-admin user and navigate to `/admin/users` --
should redirect to `/`. Sign in as admin -- should see the admin UI.

### Phase 7: Session State Patterns

The BetterAuth Vue client returns reactive Refs that have specific unwrapping
requirements.

**7.1 Using `useSession()` in components**

```vue
<script setup lang="ts">
const { $auth } = useNuxtApp();
const session = $auth.useSession();

// session is a Ref with this shape:
// session.value = {
//   isPending: boolean,
//   data: {
//     user: { id, name, email, role, ... } | null,
//     session: { ... } | null,
//   } | null,
// }
</script>

<template>
  <div v-if="session.isPending">Loading...</div>
  <div v-else-if="session.data?.user">
    Welcome, {{ session.data.user.name }}
  </div>
</template>
```

**7.2 Using `useSession()` in composables**

In composables, you must use `toValue()` to safely unwrap the session Ref inside
computed properties:

```typescript
import { computed, toValue } from "vue";

export function useSettings() {
  const { $auth } = useNuxtApp();
  const session = $auth.useSession();

  // CORRECT: Use toValue() to unwrap the Ref
  const currentUser = computed(() => {
    const s = toValue(session);
    return s?.data?.user;
  });

  // WRONG: Direct .value access inside computed can lose reactivity
  // const currentUser = computed(() => session.value?.data?.user);
  // (This sometimes works but is unreliable with BetterAuth's internal Ref structure)

  return { currentUser };
}
```

**7.3 Watching session changes**

```typescript
// Wait for session to load, then react
watch(
  () => session.value,
  (sess) => {
    if (sess?.isPending) return; // Still loading, skip
    if (!sess?.data?.user) {
      // Not authenticated
      navigateTo("/sign-in");
    }
  },
  { immediate: true }
);
```

**Why `{ immediate: true }`:** Without it, the watcher doesn't fire on initial
load, and the redirect logic doesn't run until the session changes. With it, the
check runs immediately when the component mounts.

### Phase 8: Making Authenticated API Calls

Every `fetch` call to the API must include `credentials: 'include'` so cookies
are sent through the proxy.

**8.1 The pattern**

```typescript
async function fetchUsers() {
  const response = await fetch("/api/admin/users", {
    credentials: "include", // REQUIRED: sends cookies through proxy
  });

  if (!response.ok) {
    throw new Error(`Failed to fetch users: ${response.status}`);
  }

  return await response.json();
}
```

**Why `credentials: 'include'` is needed:** Even though the request is
same-origin (thanks to the proxy), the `fetch` API defaults to `same-origin` for
credentials. BetterAuth's session cookie has specific attributes that require
explicit credential inclusion. Without this, the API sees no session and
returns 401.

**8.2 Pattern for pages with admin data**

```vue
<script setup lang="ts">
definePageMeta({ layout: "admin" });

const data = ref(null);
const isLoading = ref(true);
const error = ref("");

async function loadData() {
  isLoading.value = true;
  error.value = "";

  try {
    const response = await fetch("/api/admin/your-endpoint", {
      credentials: "include",
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    data.value = await response.json();
  } catch (err) {
    error.value = err instanceof Error ? err.message : "Failed to load data";
  } finally {
    isLoading.value = false;
  }
}

onMounted(() => loadData());
</script>
```

**Validate:** Open DevTools Network tab. Make an admin API call. Verify the
request includes a `Cookie` header and the response returns data (not 401).

### Phase 9: Sign-In Page

**9.1 The sign-in flow**

```vue
<script setup lang="ts">
const { $auth } = useNuxtApp();
const session = $auth.useSession();
const route = useRoute();

const email = ref("");
const password = ref("");
const error = ref("");
const isLoading = ref(false);

// Redirect path from query param (set by auth middleware)
const redirectTo = computed(() => {
  const redirect = route.query.redirect;
  return typeof redirect === "string" ? redirect : "/";
});

// If already signed in, redirect immediately
watch(
  () => session.value,
  (sess) => {
    if (sess?.isPending) return;
    if (sess?.data?.user) {
      navigateTo(redirectTo.value);
    }
  },
  { immediate: true }
);

async function handleSignIn() {
  isLoading.value = true;
  error.value = "";

  try {
    const result = await $auth.signIn.email({
      email: email.value,
      password: password.value,
    });

    if (result.error) {
      // BetterAuth returns errors in result.error, not via exceptions
      if (result.error.code === "EMAIL_NOT_VERIFIED") {
        // Handle email verification flow
        error.value = "Please verify your email first.";
        return;
      }
      error.value = result.error.message || "Sign in failed";
      return;
    }

    // Success -- session watcher will handle redirect
    navigateTo(redirectTo.value);
  } catch (err) {
    error.value = "An unexpected error occurred";
  } finally {
    isLoading.value = false;
  }
}
</script>
```

**Key details:**

- BetterAuth's `signIn.email()` returns `{ data, error }` -- it does NOT throw
  on auth failures. Check `result.error` explicitly.
- The `EMAIL_NOT_VERIFIED` error code requires special handling if you use email
  verification. Show a "Resend verification email" button when this occurs.
- Pre-fill the email from query params (`route.query.email`) to support redirect
  flows from email verification links.

**Validate:** Sign in with valid admin credentials. Verify redirect to the admin
dashboard. Sign in with wrong password -- should show error. Sign in as
non-admin -- should redirect to `/` (handled by index page or admin layout).

## Data Flow

### Complete Auth Request Lifecycle

```
1. Browser: POST /api/auth/sign-in/email { email, password }
   (request goes to Nuxt server on port 3000)

2. Nuxt routeRules proxy: forwards to http://localhost:3011/api/auth/sign-in/email
   (preserves all headers)

3. Elysia receives request → BetterAuth handler processes sign-in
   → Creates session in database
   → Returns response with Set-Cookie header

4. Nuxt proxy forwards response back to browser
   (preserves Set-Cookie header because same origin)

5. Browser stores cookie for localhost:3000

6. Subsequent requests: GET /api/admin/users
   Browser attaches cookie (same origin)
   → Nuxt proxies to Elysia with cookie
   → sessionMiddleware calls auth.api.getSession({ headers })
   → BetterAuth reads cookie, finds session in database
   → requireAdmin checks user.role
   → Route handler returns data
```

### Session State Flow in Vue

```
$auth.useSession() returns Ref<{
  isPending: boolean,         // true while fetching session
  data: {
    user: User | null,        // null if not authenticated
    session: Session | null,
  } | null,
}>

Component lifecycle:
1. Mount: session.value.isPending = true
2. Client-side fetch to /api/auth/get-session
3. Response received: isPending = false, data populated
4. watchEffect/watch triggers fire with resolved data
5. UI updates reactively
```

## Integration Points

- **Existing Elysia API:** The admin dashboard is a separate Nuxt app that
  connects to your existing API via proxy. No changes to the API architecture
  are needed beyond adding admin routes and guards.

- **BetterAuth plugins:** Client plugins (`adminClient`, `usernameClient`) must
  mirror server plugins (`admin`, `username`). A mismatch causes runtime errors
  when calling methods that don't exist on the server.

- **Monorepo structure:** If using a monorepo (Turborepo, etc.), the admin app
  is a separate app (`apps/admin`) that depends on no shared packages -- it
  communicates purely via HTTP to the API.

- **Deployment:** In production, `NUXT_PUBLIC_API_URL` must point to the
  internal API URL (not the public URL). The Nuxt server proxies to the API, so
  the browser never needs to know the API's actual address.

## Settings / Configuration

| Setting               | Default                 | Purpose                             |
| --------------------- | ----------------------- | ----------------------------------- |
| `NUXT_PUBLIC_API_URL` | `http://localhost:3011` | Elysia API URL (used by Nuxt proxy) |
| `ADMIN_EMAIL`         | (none)                  | Email of user to promote to admin   |

## Gotchas & Important Notes

- **Every `fetch` call needs `credentials: 'include'`.** This is the #1 source
  of "it works in the browser DevTools but not in code" bugs. Without it,
  cookies are not sent, and the API returns 401. There is no way to set this
  globally for `fetch` -- you must include it on every call.

- **Auth middleware MUST skip the server.** The `if (import.meta.server) return`
  guard in the auth middleware is not optional. Without it, every SSR request
  fails the auth check (no browser cookies available) and redirects to sign-in,
  causing an infinite redirect loop.

- **`routeRules` proxy, not `nitro.devProxy`.** Use `routeRules` for the API
  proxy, not Nitro's `devProxy`. The `devProxy` only works during `nuxt dev` and
  silently stops working in production builds. `routeRules` works everywhere.

- **No `baseURL` in `createAuthClient()`.** BetterAuth defaults to `/api/auth`
  on the current origin. Setting an explicit `baseURL` pointing to the Elysia
  server bypasses the Nuxt proxy and breaks cookie handling. Let the proxy
  handle routing.

- **`admin()` plugin doesn't auto-enforce anything.** Adding the `admin()`
  plugin to BetterAuth gives you the `user.role` field and admin API endpoints.
  It does NOT automatically protect any routes. You must explicitly
  `.use(requireAdmin)` on every admin route group in Elysia.

- **Session `isPending` must be checked before accessing data.** If you read
  `session.value.data.user` before `isPending` is false, you get null and
  incorrectly treat the user as unauthenticated. Always guard with
  `if (session.value?.isPending) return` in watchers and watchEffects.

- **Use `toValue()` to unwrap session in composables.** Inside `computed()`
  properties, `$auth.useSession()` returns a Ref that needs `toValue()`
  unwrapping. Direct `.value` access can lose reactivity with BetterAuth's
  internal Ref structure.

- **BetterAuth `signIn.email()` does not throw on auth failures.** It returns
  `{ data, error }`. If you wrap it in try/catch expecting exceptions on wrong
  passwords, you'll miss the error. Always check `result.error` explicitly.

- **The Nuxt-side role check is UX, not security.** The admin layout's
  `user.role !== 'admin'` check prevents showing admin UI to regular users, but
  a determined user could still hit admin API endpoints directly. The Elysia
  `requireAdmin` guard is the actual security boundary. Both layers are needed.

- **Client plugins must match server plugins.** If the BetterAuth server uses
  `username()`, the client must use `usernameClient()`. If the server uses
  `admin()`, the client must use `adminClient()`. Mismatches cause "method not
  found" or "unexpected field" errors that are hard to diagnose.

- **First admin user requires manual promotion.** BetterAuth doesn't have a
  "first user is admin" feature. You need a script, a Docker job, or a direct
  database update to set the first user's role to `'admin'`. Plan for this in
  your deployment process.
