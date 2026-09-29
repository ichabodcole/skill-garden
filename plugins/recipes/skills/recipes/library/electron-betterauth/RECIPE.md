# Electron + BetterAuth Secure Authentication Recipe

## Purpose

Implement secure user authentication in an Electron desktop app using BetterAuth
as the auth provider and Electron's `safeStorage` API for OS-level token
encryption. This recipe captures the integration glue between Electron's
multi-process architecture, BetterAuth's session model, and OS keychain services
-- the parts that are fundamentally different from browser-based auth and not
covered by any single library's documentation.

## When to Use

- Adding user authentication to an Electron app
- Integrating BetterAuth with Electron (not a browser, so cookie-based flows
  don't work)
- Storing tokens securely in a desktop app with OS keychain encryption
- Implementing automatic token refresh in Electron with a main/renderer split
- Building a login/logout flow that survives app restarts

## Technology Stack

| Layer             | Technology                           | Version |
| ----------------- | ------------------------------------ | ------- |
| Desktop Framework | Electron                             | 35+     |
| Auth Provider     | BetterAuth (client + server)         | 1.4+    |
| Token Encryption  | Electron safeStorage API             | --      |
| Token Persistence | electron-store                       | 8+      |
| State Management  | Pinia (Vue) or Zustand/Jotai (React) | --      |
| UI Framework      | Vue 3 / React (renderer process)     | --      |

## Architecture Overview

### Why This Is Different From Browser Auth

In a browser, BetterAuth uses HTTP-only cookies for session management. Electron
is **not a browser** in the auth sense:

- Cookies set via `Set-Cookie` are unreliable across Electron updates and
  security policies
- The renderer process is sandboxed -- it cannot access Node.js APIs or the OS
  keychain
- Tokens must persist across app restarts (in-memory storage is not enough)
- The main process is the only place with access to OS-level encryption

**Result:** You must manually manage tokens with Bearer auth headers instead of
relying on cookies. This recipe implements that pattern.

### Security Model

```
RENDERER PROCESS (untrusted, sandboxed)
  - Calls window.secureStorage.setToken() / getToken()
  - NEVER sees raw encryption keys or OS keychain
  - Context isolation enabled, nodeIntegration disabled
        |
        | IPC (contextBridge)
        | Limited API surface: set, get, delete, clear, isAvailable
        |
PRELOAD (security bridge)
  - Maps window.secureStorage methods to ipcRenderer.invoke()
  - Strictly typed, minimal surface area
        |
        | ipcMain.handle()
        |
MAIN PROCESS (trusted, has Node.js access)
  - Owns safeStorage API (OS keychain access)
  - Encrypts tokens before writing to disk
  - Decrypts tokens on retrieval
  - Persists encrypted blobs via electron-store
```

**Key security principles:**

1. Tokens NEVER exist in plaintext in the renderer process
2. Main process owns all encryption -- safeStorage is only available there
3. Context isolation is mandatory -- renderer cannot access Node.js/Electron
   APIs
4. Even if the renderer is compromised (XSS), tokens remain encrypted in the
   main process
5. The IPC bridge has a minimal API surface -- only token CRUD operations

### Component Overview

```
Renderer Process:
  UI Components (LoginForm, AccountProfile)
      |
  Auth Store (Pinia/Zustand) -- state: user, isLoading, isAuthenticated
      |
  Token Service -- abstraction over window.secureStorage IPC
  Auth Client -- BetterAuth SDK with fetchOptions.onRequest hook
  API Client -- authenticatedFetch() with auto-refresh on 401
      |
      | window.secureStorage.setToken() / getToken()
      |
Preload:
  contextBridge.exposeInMainWorld('secureStorage', { ... })
      |
      | ipcRenderer.invoke('secure-storage:set', ...)
      |
Main Process:
  Secure Storage IPC Handlers -- registers ipcMain.handle()
      |
  Secure Storage Service -- encrypt/decrypt/persist via safeStorage + electron-store
```

## Implementation Process

### Phase 1: Secure Storage Service (Main Process)

This is the foundation. Build it first because everything else depends on it.

**1.1 Create the secure storage service**

Location: `src/main/secure-storage-service.ts`

This service wraps Electron's `safeStorage` API and persists encrypted tokens
using `electron-store`.

```typescript
import { safeStorage } from "electron";
import ElectronStore from "electron-store";

// Define the allowed token keys
type SecureStorageKey = "accessToken" | "refreshToken";

interface SecureStorageResult<T = string> {
  success: boolean;
  data?: T;
  error?: string;
}

// Persistent store for encrypted token blobs
// Do NOT set encryptionKey here -- tokens are already encrypted by safeStorage
const tokenStore = new ElectronStore<Record<SecureStorageKey, string>>({
  name: "secure-tokens",
  encryptionKey: undefined,
});

function isSecureStorageAvailable(): boolean {
  return safeStorage.isEncryptionAvailable();
}

function setToken(
  key: SecureStorageKey,
  value: string
): SecureStorageResult<void> {
  if (!isSecureStorageAvailable()) {
    return { success: false, error: "Secure storage not available" };
  }
  try {
    // 1. Encrypt with OS keychain
    const encrypted = safeStorage.encryptString(value);
    // 2. Convert to base64 for serialization
    const base64 = encrypted.toString("base64");
    // 3. Persist encrypted blob to disk
    tokenStore.set(key, base64);
    return { success: true };
  } catch (error) {
    return { success: false, error: `Encryption failed: ${error}` };
  }
}

function getToken(key: SecureStorageKey): SecureStorageResult<string> {
  if (!isSecureStorageAvailable()) {
    return { success: false, error: "Secure storage not available" };
  }
  try {
    const base64 = tokenStore.get(key);
    if (!base64) return { success: true, data: undefined };
    // Reverse: base64 -> Buffer -> decrypt
    const encrypted = Buffer.from(base64, "base64");
    const decrypted = safeStorage.decryptString(encrypted);
    return { success: true, data: decrypted };
  } catch (error) {
    return { success: false, error: `Decryption failed: ${error}` };
  }
}

function deleteToken(key: SecureStorageKey): SecureStorageResult<void> {
  try {
    tokenStore.delete(key);
    return { success: true };
  } catch (error) {
    return { success: false, error: `Delete failed: ${error}` };
  }
}

function clearAllTokens(): SecureStorageResult<void> {
  try {
    tokenStore.clear();
    return { success: true };
  } catch (error) {
    return { success: false, error: `Clear failed: ${error}` };
  }
}
```

**Critical detail:** `safeStorage.encryptString()` encrypts using the OS
keychain but does NOT persist. `electron-store` persists but does NOT encrypt.
You need both together -- safeStorage for encryption, electron-store for
persistence. An early mistake is using only one, which either loses tokens on
restart (no persistence) or stores them in plaintext (no encryption).

**1.2 Register IPC handlers**

Location: `src/main/secure-storage-ipc.ts`

```typescript
import { ipcMain } from "electron";
import {
  isSecureStorageAvailable,
  setToken,
  getToken,
  deleteToken,
  clearAllTokens,
} from "./secure-storage-service";

export function registerSecureStorageHandlers(): void {
  ipcMain.handle("secure-storage:is-available", () =>
    isSecureStorageAvailable()
  );
  ipcMain.handle("secure-storage:set", (_, key, value) => setToken(key, value));
  ipcMain.handle("secure-storage:get", (_, key) => getToken(key));
  ipcMain.handle("secure-storage:delete", (_, key) => deleteToken(key));
  ipcMain.handle("secure-storage:clear", () => clearAllTokens());
}
```

**1.3 Call during app initialization**

In your main process entry point (e.g., `src/main/index.ts`), call
`registerSecureStorageHandlers()` during app startup, BEFORE creating any
BrowserWindow. This ensures the IPC handlers are ready when the renderer loads.

```typescript
app.whenReady().then(async () => {
  // Register IPC handlers BEFORE creating windows
  registerSecureStorageHandlers();

  // Then create your BrowserWindow
  createMainWindow();
});
```

**Validate:** At this point, you can test from the renderer DevTools:
`await window.secureStorage.setToken('accessToken', 'test')` should return
`{ success: true }`, and `await window.secureStorage.getToken('accessToken')`
should return `{ success: true, data: 'test' }`.

### Phase 2: Preload Bridge

**2.1 Expose secureStorage via contextBridge**

Location: `src/preload/index.ts`

```typescript
import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("secureStorage", {
  isAvailable: (): Promise<boolean> =>
    ipcRenderer.invoke("secure-storage:is-available"),

  setToken: (key: "accessToken" | "refreshToken", value: string) =>
    ipcRenderer.invoke("secure-storage:set", key, value),

  getToken: (key: "accessToken" | "refreshToken") =>
    ipcRenderer.invoke("secure-storage:get", key),

  deleteToken: (key: "accessToken" | "refreshToken") =>
    ipcRenderer.invoke("secure-storage:delete", key),

  clearAll: () => ipcRenderer.invoke("secure-storage:clear"),
});
```

**2.2 Add TypeScript declarations**

Location: `src/preload/index.d.ts` (or wherever your global types live)

```typescript
declare global {
  interface Window {
    secureStorage: {
      isAvailable: () => Promise<boolean>;
      setToken: (
        key: "accessToken" | "refreshToken",
        value: string
      ) => Promise<{ success: boolean; error?: string }>;
      getToken: (
        key: "accessToken" | "refreshToken"
      ) => Promise<{ success: boolean; data?: string; error?: string }>;
      deleteToken: (
        key: "accessToken" | "refreshToken"
      ) => Promise<{ success: boolean; error?: string }>;
      clearAll: () => Promise<{ success: boolean; error?: string }>;
    };
  }
}
```

**Key constraint:** The preload script restricts the key type to only
`'accessToken' | 'refreshToken'`. The main process may support additional keys
(e.g., for JWT secrets), but the renderer should only have access to auth
tokens. This is a deliberate restriction of the API surface.

**Validate:** Ensure your BrowserWindow config has context isolation enabled:

```typescript
webPreferences: {
  contextIsolation: true,
  nodeIntegration: false,
  sandbox: true,
  preload: path.join(__dirname, '../preload/index.js'),
}
```

### Phase 3: Token Service (Renderer Abstraction)

**3.1 Create a token service**

Location: `src/renderer/src/services/token-service.ts`

This service provides a clean API over `window.secureStorage` so that the rest
of the renderer code never calls IPC directly.

```typescript
export async function isSecureStorageAvailable(): Promise<boolean> {
  return await window.secureStorage.isAvailable();
}

export async function getAccessToken(): Promise<string | null> {
  const result = await window.secureStorage.getToken("accessToken");
  if (!result.success) {
    console.error("Failed to get access token:", result.error);
    return null;
  }
  return result.data || null;
}

export async function getRefreshToken(): Promise<string | null> {
  const result = await window.secureStorage.getToken("refreshToken");
  if (!result.success) {
    console.error("Failed to get refresh token:", result.error);
    return null;
  }
  return result.data || null;
}

export async function setTokens(
  accessToken: string,
  refreshToken: string
): Promise<{ success: boolean; error?: string }> {
  const accessResult = await window.secureStorage.setToken(
    "accessToken",
    accessToken
  );
  if (!accessResult.success)
    return { success: false, error: accessResult.error };

  const refreshResult = await window.secureStorage.setToken(
    "refreshToken",
    refreshToken
  );
  if (!refreshResult.success)
    return { success: false, error: refreshResult.error };

  return { success: true };
}

export async function clearTokens(): Promise<{
  success: boolean;
  error?: string;
}> {
  return await window.secureStorage.clearAll();
}
```

**Why this abstraction exists:** It provides consistent error handling, type
safety, and a single place to add logging or telemetry for token operations.
Components and stores import from `token-service`, never from
`window.secureStorage` directly.

### Phase 4: BetterAuth Client Configuration

**4.1 Configure the BetterAuth client for Electron**

Location: `src/renderer/src/lib/auth-client.ts`

The critical difference from browser usage: inject the access token into every
request via `fetchOptions.onRequest`. In a browser, BetterAuth relies on
cookies. In Electron, you must manually attach the Bearer token.

```typescript
import { createAuthClient } from "better-auth/client";
import {
  usernameClient,
  inferAdditionalFields,
} from "better-auth/client/plugins";

export const authClient = createAuthClient({
  baseURL: "https://your-api.example.com", // Your API server
  plugins: [
    usernameClient(),
    inferAdditionalFields({
      user: {
        username: { type: "string" },
        displayUsername: { type: "string" },
      },
    }),
  ],
  // KEY ELECTRON DIFFERENCE: Inject token manually since cookies don't work
  fetchOptions: {
    onRequest: async (context) => {
      const result = await window.secureStorage.getToken("accessToken");
      if (result.success && result.data) {
        context.headers.set("Authorization", `Bearer ${result.data}`);
      }
    },
  },
});
```

**Why `fetchOptions.onRequest`:** BetterAuth's client uses `fetch` internally
for all API calls (signIn, signOut, getSession, etc.). By hooking into
`onRequest`, you ensure every BetterAuth request includes the token without
modifying each call site.

**Validate:** After sign-in, `authClient.getSession()` should return user data.
If it returns null, the token is not being attached -- check the `onRequest`
hook.

### Phase 5: Auth Store (State Management)

**5.1 Create the auth store**

Location: `src/renderer/src/stores/auth.store.ts` (Pinia example)

The store manages four concerns:

1. **Sign-in:** Call BetterAuth, store tokens, update state
2. **Session restoration:** On app startup, check for stored tokens and validate
3. **Auth expiration:** Detect expired sessions, notify UI without forcing
   logout
4. **Sign-out:** Clear tokens, clear state, reset dependent services

```typescript
import { defineStore } from "pinia";
import { computed, ref } from "vue";
import { authClient, type User } from "@/lib/auth-client";
import {
  getAccessToken,
  getRefreshToken,
  setTokens,
  clearTokens,
  isSecureStorageAvailable,
} from "@/services/token-service";

export const useAuthStore = defineStore("auth", () => {
  const user = ref<User | null>(null);
  const isLoading = ref(false);
  const isAuthExpired = ref(false);
  const isAuthenticated = computed(() => user.value !== null);

  // --- Session Restoration (app startup) ---
  const initializeAuth = async (): Promise<void> => {
    try {
      isLoading.value = true;

      // 1. Check if OS keychain is available (Linux edge case)
      if (!(await isSecureStorageAvailable())) {
        console.warn("Secure storage unavailable - auth disabled");
        return;
      }

      // 2. Check for stored tokens
      const accessToken = await getAccessToken();
      const refreshToken = await getRefreshToken();
      if (!accessToken && !refreshToken) return; // No stored session

      // 3. Optimistically restore cached user data (avoid flash of logged-out UI)
      // Load from settings/localStorage if available
      restoreCachedUser();

      // 4. Validate session with server (refresh-first pattern)
      const refreshed = await refreshSession();
      if (!refreshed) {
        console.info("Session validation failed (keeping tokens for retry)");
      }
    } finally {
      isLoading.value = false;
    }
  };

  // --- Sign In ---
  const signIn = async (email: string, password: string): Promise<void> => {
    try {
      isLoading.value = true;

      const result = await authClient.signIn.email({ email, password });
      if (!result.data) throw new Error("Sign-in failed: no data returned");

      const { user: userData, token } = result.data;

      // BetterAuth returns a single token -- use it for both access and refresh
      const tokenResult = await setTokens(token, token);
      if (!tokenResult.success) {
        throw new Error(`Failed to store tokens: ${tokenResult.error}`);
      }

      // Update state
      user.value = mapUserData(userData);
      isAuthExpired.value = false;

      // Cache user data for optimistic restore on next startup
      cacheUserData(user.value);
    } finally {
      isLoading.value = false;
    }
  };

  // --- Session Refresh ---
  const refreshSession = async (): Promise<boolean> => {
    try {
      const result = await authClient.getSession();
      if (!result.data) {
        const status = result.error?.status;
        if (status === 401 || status === 403) {
          // Session explicitly invalid -- clear tokens
          await handleAuthExpired();
        }
        // For network errors, keep tokens for retry on next startup
        return false;
      }

      user.value = mapUserData(result.data.user);
      cacheUserData(user.value);
      return true;
    } catch (error) {
      // Network error -- don't clear tokens, user may be offline
      return false;
    }
  };

  // --- Auth Expiration ---
  const handleAuthExpired = async (): Promise<void> => {
    const wasAlreadyExpired = isAuthExpired.value;
    isAuthExpired.value = true;
    await clearTokens();

    if (!wasAlreadyExpired) {
      // Show notification only on first detection
      showExpirationNotification();
    }
  };

  // --- Sign Out ---
  const signOut = async (): Promise<void> => {
    try {
      isLoading.value = true;

      // 1. Revoke session server-side (best-effort)
      try {
        await authClient.signOut();
      } catch {
        /* continue */
      }

      // 2. Clear local tokens
      await clearTokens();

      // 3. Clear state
      user.value = null;
      isAuthExpired.value = false;

      // 4. Clear cached user data
      clearCachedUser();

      // 5. Reset dependent services (sync, etc.)
      await resetDependentServices();
    } finally {
      isLoading.value = false;
    }
  };

  return {
    user,
    isLoading,
    isAuthExpired,
    isAuthenticated,
    initializeAuth,
    signIn,
    signOut,
    refreshSession,
    handleAuthExpired,
  };
});
```

**5.2 Initialize auth on app mount**

Call `initializeAuth()` early in your app lifecycle. In Vue, this is `App.vue`'s
`onMounted`:

```typescript
// App.vue
import { useAuthStore } from "@/stores/auth.store";

onMounted(async () => {
  const authStore = useAuthStore();
  await authStore.initializeAuth();
});
```

**Validate:** After implementing, restart the app. If you were previously signed
in, the app should automatically restore the session without showing a login
form.

### Phase 6: Authenticated API Client

**6.1 Create an authenticated fetch wrapper with auto-refresh**

Location: `src/renderer/src/services/api-client.ts`

This handles the token refresh lifecycle transparently for all API calls.

```typescript
import { getAccessToken, getRefreshToken, setTokens } from "./token-service";

const API_BASE_URL = "https://your-api.example.com";

// Refresh mutex -- prevents race conditions
let isRefreshing = false;
let refreshPromise: Promise<boolean> | null = null;

async function attemptTokenRefresh(): Promise<boolean> {
  // If already refreshing, reuse the in-progress promise
  if (isRefreshing && refreshPromise) {
    return await refreshPromise;
  }

  isRefreshing = true;
  refreshPromise = (async () => {
    try {
      const refreshToken = await getRefreshToken();
      if (!refreshToken) return false;

      const response = await fetch(`${API_BASE_URL}/api/auth/refresh`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ refreshToken }),
      });

      if (!response.ok) return false;

      const { accessToken, refreshToken: newRefreshToken } =
        await response.json();
      if (!accessToken || !newRefreshToken) return false;

      const result = await setTokens(accessToken, newRefreshToken);
      return result.success;
    } catch {
      return false;
    } finally {
      isRefreshing = false;
      refreshPromise = null;
    }
  })();

  return await refreshPromise;
}

export async function authenticatedFetch(
  url: string,
  options: RequestInit = {}
): Promise<Response> {
  const accessToken = await getAccessToken();
  if (!accessToken) throw new Error("No access token available");

  const response = await fetch(url, {
    ...options,
    headers: { ...options.headers, Authorization: `Bearer ${accessToken}` },
  });

  // On 401: attempt refresh and retry once
  if (response.status === 401) {
    const refreshed = await attemptTokenRefresh();
    if (refreshed) {
      const newToken = await getAccessToken();
      if (newToken) {
        return await fetch(url, {
          ...options,
          headers: { ...options.headers, Authorization: `Bearer ${newToken}` },
        });
      }
    }

    // Refresh failed -- notify auth store
    const { useAuthStore } = await import("@/stores/auth.store");
    await useAuthStore().handleAuthExpired();
    throw new Error("Session expired - please sign in again");
  }

  return response;
}
```

**Why the refresh mutex matters:** When multiple API calls fire simultaneously
and the token is expired, all of them receive 401. Without the mutex, each would
independently attempt a refresh, causing race conditions and potentially
invalidating tokens that other requests just received. The mutex ensures only
one refresh happens; all others wait for its result.

**Validate:** To test, manually expire the access token (set a short expiry on
the server), then make an API call. It should transparently refresh and succeed.

### Phase 7: Main Process Authenticated Fetch (Optional)

If the main process also needs to make authenticated API requests (e.g., for
sync credential fetching), it needs its own authenticated fetch that reads
tokens directly from the secure storage service (no IPC needed since it's
already in the main process).

```typescript
// src/main/operator-api-client.ts
import { getToken } from "./secure-storage-service";

export async function authenticatedFetch(
  path: string,
  options: RequestInit = {}
): Promise<Response> {
  const url = `${API_BASE_URL}${path}`;
  const result = getToken("accessToken"); // Direct call, no IPC
  const accessToken = result.success ? result.data : null;

  return fetch(url, {
    ...options,
    headers: {
      ...options.headers,
      ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
    },
  });
}
```

**Note:** The main process calls `getToken()` synchronously (not via IPC). It
has direct access to the secure storage service. This is a key architectural
difference from the renderer, which must always go through the IPC bridge.

## Data Flow

### Sign-In Flow

```
1. User enters credentials → Login form component
2. Form calls → authStore.signIn(email, password)
3. Store calls → authClient.signIn.email({ email, password })
4. BetterAuth returns → { user, token }
5. Store calls → setTokens(token, token)
6. Token service calls → window.secureStorage.setToken('accessToken', token)
7. IPC invokes → ipcMain.handle('secure-storage:set', ...)
8. Main process → safeStorage.encryptString(token) → tokenStore.set(key, base64)
9. Store updates → user.value = userData
10. UI reacts → Shows authenticated state
```

### Session Restoration (App Startup)

```
1. App mounts → authStore.initializeAuth()
2. Check → isSecureStorageAvailable() (Linux may fail)
3. Retrieve → getAccessToken() via IPC → main decrypts → returns token
4. If token exists → Optimistically restore cached user (avoid UI flash)
5. Validate → authClient.getSession() (attaches token via onRequest hook)
6. If valid → Update user state with fresh server data
7. If 401/403 → handleAuthExpired() → clear tokens, show notification
8. If network error → Keep tokens, keep cached user (offline-friendly)
```

### Token Refresh on 401

```
1. authenticatedFetch() gets 401 response
2. Check mutex → If refresh in progress, wait for it
3. Start refresh → POST /api/auth/refresh with refresh token
4. Server returns → New access + refresh tokens (old refresh invalidated)
5. Store new tokens → setTokens(newAccess, newRefresh)
6. Retry original request → With new access token
7. If refresh fails → handleAuthExpired() → clear tokens, notify UI
```

### Sign-Out Flow

```
1. User clicks sign out → Account UI component
2. Call → authStore.signOut()
3. Best-effort → authClient.signOut() (revoke server-side)
4. Clear → clearTokens() via IPC → main process clears electron-store
5. Reset → user.value = null, clear cached data
6. Cleanup → Reset sync state, clear dependent services
7. UI reacts → Shows unauthenticated state
```

## Key Patterns

### Refresh-First Startup

On app launch, use the refresh token immediately. Do NOT try the access token
first.

**Why:** Access tokens are typically short-lived (15 minutes). After the app has
been closed for hours or days, the access token is almost certainly expired.
Attempting it first just produces an unnecessary 401 before refreshing anyway.

### Optimistic User Restoration

Cache user data (name, email, avatar) in non-encrypted storage (like
electron-store settings). On startup, restore this cached data immediately
BEFORE validating the session with the server. This prevents a "flash of
logged-out state" in the UI.

**Separation:** Sensitive tokens go in safeStorage-encrypted storage.
Non-sensitive user display data goes in plain settings storage.

### Graceful Auth Expiration

When a token refresh fails, do NOT immediately log the user out. Instead:

1. Set an `isAuthExpired` flag
2. Clear tokens (they're invalid anyway)
3. Show a notification: "Session expired. Sign in again to restore cloud
   features."
4. Keep the user's local workspace intact -- they can continue editing offline
5. On re-authentication, clear the expired flag and restore full functionality

This avoids the hostile pattern of force-logging users out and disrupting their
work.

### BetterAuth Single Token Pattern

BetterAuth returns a single `token` field from `signIn.email()`, not separate
access and refresh tokens. Store the same value for both:

```typescript
const { token } = result.data;
await setTokens(token, token); // Same token used for both
```

On refresh, the server may return distinct tokens. The refresh endpoint rotates
the token -- the old one is invalidated when a new one is issued.

## Integration Points

- **Sync services:** After sign-in, enable cloud sync with the authenticated
  user ID. After sign-out, reset sync state and clear sync credentials.
- **AI features:** Cloud-based AI operations require authentication. When auth
  expires, these features should be disabled gracefully.
- **App lifecycle:** `initializeAuth()` must be called on app mount. Sign-out
  may require an app restart for a clean state (clearing sync databases, etc.).
- **UI components:** A login form, account profile, and account button in the
  app chrome. The auth store drives all UI state reactively.

## Gotchas & Important Notes

### safeStorage Encrypts But Does Not Persist

`safeStorage.encryptString()` uses the OS keychain to encrypt a string, but it
returns a `Buffer` in memory. You MUST persist the encrypted buffer yourself
(using electron-store, fs, or similar). Without persistence, tokens are lost on
app restart.

**The correct pairing:** `safeStorage` for encryption + `electron-store` for
persistence.

### Linux Secret Service May Not Be Available

`safeStorage.isEncryptionAvailable()` returns false on Linux systems without
gnome-keyring or KWallet. You must check availability before any auth operations
and show a clear error message to users. Do not silently fall back to
unencrypted storage.

### electron-store Default Export Issue

Depending on your bundler and electron-store version, the default export may be
wrapped. Handle both cases:

```typescript
const ElectronStore =
  (ElectronStoreImport as unknown as { default?: typeof ElectronStoreImport })
    .default ?? ElectronStoreImport;
```

### Don't Encrypt the electron-store Itself

electron-store has its own `encryptionKey` option. Do NOT use it when storing
safeStorage-encrypted tokens -- the tokens are already encrypted. Double
encryption adds complexity without security benefit and makes debugging harder.

### Register IPC Handlers Before Creating Windows

If IPC handlers are not registered before the renderer loads, the first
`window.secureStorage` call will fail with "No handler registered for channel."
Always call `registerSecureStorageHandlers()` in `app.whenReady()` before
`createWindow()`.

### Context Isolation Is Non-Negotiable

Your BrowserWindow MUST have these settings:

```typescript
webPreferences: {
  contextIsolation: true,   // Required for security boundary
  nodeIntegration: false,    // Renderer cannot access Node.js
  sandbox: true,             // Additional process isolation
}
```

Without context isolation, the entire security model of this recipe collapses --
the renderer could directly access safeStorage, bypassing the IPC bridge.

### Network Errors vs Auth Errors

When session validation fails during `initializeAuth()`, distinguish between:

- **401/403:** Session is explicitly invalid. Clear tokens, show expiration
  notification.
- **Network error (timeout, DNS, etc.):** Server may be unreachable. Do NOT
  clear tokens. Keep the cached user data and try again later.

Clearing tokens on network errors forces unnecessary re-logins when the user is
simply offline.

### Sign-Out May Require App Restart

If your app has stateful services that depend on the authenticated user (like
sync databases scoped to a user ID), signing out may require an app restart to
fully reset state. Set an `awaitingRestart` flag and prompt the user rather than
trying to hot-reload everything.
