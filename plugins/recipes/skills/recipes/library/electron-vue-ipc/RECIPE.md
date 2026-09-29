# Electron + Vue 3 IPC Architecture Recipe

## Purpose

Implement a secure, typed IPC architecture for Electron desktop apps using Vue
3, Pinia, and TypeScript. This recipe captures the integration glue between
Electron's three-process model and Vue's reactivity system - specifically how to
structure the preload bridge, modular IPC handlers, and Pinia stores so that
each layer has clear responsibilities and the renderer process never touches
Node.js APIs directly.

## When to Use

- Starting a new Electron + Vue 3 desktop application
- Adding a new domain/feature to an existing Electron app (new IPC endpoints)
- Refactoring an Electron app to use proper process isolation
- The user references "Electron IPC recipe", "typed preload bridge", or similar

## Technology Stack

| Layer     | Technology                       | Version |
| --------- | -------------------------------- | ------- |
| Shell     | Electron                         | 35+     |
| Build     | electron-vite (or Vite)          | 3+      |
| Frontend  | Vue 3 (Composition API)          | 3.5+    |
| State     | Pinia                            | 2.3+    |
| Language  | TypeScript                       | 5.0+    |
| Utilities | @electron-toolkit/preload, utils | latest  |

## Architecture Overview

Electron enforces a three-process security model. Each process has different
capabilities and a strict communication contract:

```
┌────────────────────────────────────────────────────────┐
│  Renderer Process (Vue 3 + Pinia)                      │
│  - Vue components (UI only, no IPC calls)              │
│  - Pinia stores (SOLE callers of window.* APIs)        │
│  - No Node.js access, no require(), no fs              │
│  - Path alias: @/ -> src/renderer/src/                 │
└───────────────────┬────────────────────────────────────┘
                    │ window.{namespace}.{method}()
┌───────────────────▼────────────────────────────────────┐
│  Preload Script (Security Bridge)                      │
│  - contextBridge.exposeInMainWorld()                   │
│  - ipcRenderer.invoke() / ipcRenderer.on()             │
│  - Type definitions (index.d.ts) for autocomplete      │
│  - ZERO business logic - pure pass-through             │
└───────────────────┬────────────────────────────────────┘
                    │ IPC channel: 'domain:operation'
┌───────────────────▼────────────────────────────────────┐
│  Main Process (Node.js)                                │
│  - IPC handlers (*-ipc.ts) - thin bridge layer         │
│  - Services (*-service.ts) - business logic + DB       │
│  - Full Node.js access (fs, net, child_process, etc.)  │
│  - Path alias: @shared/ -> src/shared/                 │
└────────────────────────────────────────────────────────┘
```

### Why Three Processes?

1. **Security.** The renderer runs untrusted content (user markdown, web views).
   It must NEVER have direct access to Node.js APIs like `fs` or
   `child_process`. The preload script is the controlled gateway.

2. **Type safety.** The preload bridge defines an explicit typed contract
   (`window.*` APIs) that both the renderer and main process agree on. This
   prevents subtle bugs from mismatched IPC arguments.

3. **Testability.** Each layer can be tested independently: services with unit
   tests, stores with mocked `window.*`, components with mocked stores.

### Key Design Decisions

- **Pinia stores are the sole IPC callers.** Vue components never call
  `window.documents.create()` directly. They call store actions, which call
  `window.*`, which triggers IPC. This keeps components pure UI and makes IPC
  usage auditable in one place per domain.

- **Each domain gets its own `*-ipc.ts` file.** Instead of one giant IPC handler
  file, each domain (documents, settings, versions, projects, etc.) has a
  dedicated setup function. This keeps files focused and makes it easy to find
  handlers.

- **IPC handlers are thin.** They call service methods and return results.
  Business logic, validation, and database access live in `*-service.ts` files,
  not in IPC handlers.

- **Namespace-isolated preload APIs.** Each domain is exposed as a separate
  `window.*` namespace (`window.documents`, `window.settings`,
  `window.versions`). This prevents naming collisions and makes the API surface
  self-documenting.

## Directory Structure

```
src/
├── main/                          # Main process (Node.js)
│   ├── index.ts                   # App entry, IPC registration
│   ├── documents-ipc.ts           # setupDocumentsIPC()
│   ├── settings-ipc.ts            # setupSettingsIPC()
│   ├── versions-ipc.ts            # setupVersionsIPC()
│   ├── projects-ipc.ts            # setupProjectsIPC()
│   ├── document-service.ts        # Business logic + DB queries
│   ├── version-service.ts         # Version business logic
│   ├── project-service.ts         # Project business logic
│   └── database.ts                # Database initialization
├── preload/
│   ├── index.ts                   # contextBridge exposures
│   └── index.d.ts                 # TypeScript declarations for window.*
├── renderer/
│   └── src/
│       ├── stores/
│       │   ├── documents.store.ts # Wraps window.documents.*
│       │   ├── settings.store.ts  # Wraps window.settings.*
│       │   └── projects.store.ts  # Wraps window.projects.*
│       ├── components/            # Vue components (call stores, not IPC)
│       └── types/                 # Renderer-specific types
└── shared/                        # Types shared between all processes
    ├── types/
    │   ├── settings.ts            # Settings shape
    │   └── ...
    └── constants/
        └── ...
```

## Implementation Process

### Phase 1: Shared Types

Define types in `src/shared/` that all three processes import. This is the
contract that keeps everything in sync.

**1.1 Define shared types** (`src/shared/types/settings.ts`)

Types shared between main and preload must avoid importing renderer-specific
code. Use generics where the renderer needs to extend the base type:

```typescript
// src/shared/types/settings.ts
export interface EditorSettings {
  fontSize: number;
  theme: "light" | "dark" | "system";
}

export interface InterfaceSettings {
  sidebarVisible: boolean;
  editorMode: "edit" | "split" | "preview";
}

// Generic base so main/preload don't need renderer-only types
export type AppSettingsBase<AI = unknown> = {
  editor: EditorSettings;
  interface: InterfaceSettings;
  ai: AI;
};
```

**Why generics?** The main process may not have access to renderer-specific AI
provider types. The generic parameter lets each process fill in what it knows.

### Phase 2: Preload Bridge

The preload script is the API contract between renderer and main process. It has
two parts: the implementation (`index.ts`) and the type declarations
(`index.d.ts`).

**2.1 Expose namespace-isolated APIs** (`src/preload/index.ts`)

Each domain gets its own `contextBridge.exposeInMainWorld()` call with a
namespace string. Methods map 1:1 to IPC channels.

```typescript
// src/preload/index.ts
import { contextBridge, ipcRenderer } from "electron";
import type { AppSettingsBase } from "@shared/types/settings";

// Settings API
contextBridge.exposeInMainWorld("settings", {
  getSettings: (): Promise<AppSettingsBase> =>
    ipcRenderer.invoke("settings:get"),

  updateSettings: (settings: Partial<AppSettingsBase>): Promise<boolean> =>
    ipcRenderer.invoke("settings:update", settings),

  resetSettings: (): Promise<boolean> => ipcRenderer.invoke("settings:reset"),

  // Event listener: main -> renderer push notifications
  onSettingsChanged: (callback: (settings: AppSettingsBase) => void): void => {
    ipcRenderer.on("settings:changed", (_, settings) => callback(settings));
  },
});

// Documents API
contextBridge.exposeInMainWorld("documents", {
  create: (content: string, projectId?: string) =>
    ipcRenderer.invoke("documents:create", content, projectId),
  update: (id: string, content: string) =>
    ipcRenderer.invoke("documents:update", id, content),
  get: (id: string) => ipcRenderer.invoke("documents:get", id),
  list: (projectId?: string) => ipcRenderer.invoke("documents:list", projectId),
  delete: (id: string) => ipcRenderer.invoke("documents:delete", id),

  // Event listener for main -> renderer broadcasts
  onAgentUpdated: (
    callback: (data: { documentId: string; versionId: string }) => void
  ): void => {
    ipcRenderer.on("document:agentUpdated", (_, data) => callback(data));
  },
});
```

**Pattern: Two-way communication.** Request-response uses `ipcRenderer.invoke()`
(renderer calls main). Event broadcasting uses `ipcRenderer.on()` (main pushes
to renderer). Both are exposed through the same namespace object.

**2.2 Type declarations** (`src/preload/index.d.ts`)

This file gives the renderer full autocomplete for `window.*` APIs. It must
mirror the preload implementation exactly.

```typescript
// src/preload/index.d.ts
import type { Document, DocumentVersion } from "@your/database";

declare global {
  interface Window {
    documents: {
      create: (content: string, projectId?: string) => Promise<Document>;
      update: (id: string, content: string) => Promise<void>;
      get: (id: string) => Promise<Document | null>;
      list: (projectId?: string) => Promise<Document[]>;
      delete: (id: string) => Promise<void>;
      onAgentUpdated: (
        callback: (data: { documentId: string; versionId: string }) => void
      ) => void;
    };
    settings: {
      getSettings: () => Promise<AppSettingsBase>;
      updateSettings: (settings: Partial<AppSettingsBase>) => Promise<boolean>;
      resetSettings: () => Promise<boolean>;
      onSettingsChanged: (
        callback: (settings: AppSettingsBase) => void
      ) => void;
    };
  }
}

export {};
```

The `export {}` at the end is required to make this a module augmentation rather
than a global script.

**Validate:** At this point, the renderer should have full autocomplete for
`window.documents.*` and `window.settings.*` with correct return types.

### Phase 3: Main Process IPC Handlers

Each domain gets a dedicated `*-ipc.ts` file with a `setup*IPC()` function. This
function is called once during app initialization.

**3.1 Modular IPC handler pattern** (`src/main/documents-ipc.ts`)

IPC handlers are thin wrappers that call service methods. They accept
dependencies via an options object for testability.

```typescript
// src/main/documents-ipc.ts
import { ipcMain } from "electron";
import { documentService } from "./document-service";
import type { DocumentExportService } from "./document-export-service";
import type { Document } from "@your/database";

interface SetupDocumentsIPCOptions {
  exportService: DocumentExportService;
}

export function setupDocumentsIPC({ exportService }: SetupDocumentsIPCOptions) {
  // Create a new document
  ipcMain.handle(
    "documents:create",
    async (_event, content: string, projectId?: string): Promise<Document> => {
      return documentService.create(content, projectId);
    }
  );

  // Update document content
  ipcMain.handle(
    "documents:update",
    async (_event, id: string, content: string): Promise<void> => {
      return documentService.update(id, content);
    }
  );

  // Get a single document
  ipcMain.handle(
    "documents:get",
    async (_event, id: string): Promise<Document | null> => {
      return documentService.get(id);
    }
  );

  // List all documents
  ipcMain.handle(
    "documents:list",
    async (_event, projectId?: string): Promise<Document[]> => {
      return documentService.list(projectId);
    }
  );

  // Soft delete a document
  ipcMain.handle(
    "documents:delete",
    async (_event, id: string): Promise<void> => {
      return documentService.softDelete(id);
    }
  );
}
```

**3.2 IPC handler with dependency injection** (`src/main/settings-ipc.ts`)

Some IPC handlers need access to stores, windows, or callback functions. Pass
these as dependencies rather than importing globals.

```typescript
// src/main/settings-ipc.ts
import { ipcMain } from "electron";
import type StoreType from "electron-store";
import type { AppSettingsBase } from "@shared/types/settings";

export interface SettingsIPCDeps {
  store: StoreType<AppSettingsBase>;
  notifySettingsChanged: (settings: AppSettingsBase) => void;
}

export function setupSettingsIPC({
  store,
  notifySettingsChanged,
}: SettingsIPCDeps): void {
  ipcMain.handle("settings:get", () => {
    return store.store;
  });

  ipcMain.handle(
    "settings:update",
    (_evt, settings: Partial<AppSettingsBase>) => {
      // Deep merge into store
      const mergeIntoStore = (prefix: string, value: unknown): void => {
        if (
          value !== null &&
          typeof value === "object" &&
          !Array.isArray(value)
        ) {
          for (const [key, val] of Object.entries(value)) {
            mergeIntoStore(prefix ? `${prefix}.${key}` : key, val);
          }
        } else {
          store.set(prefix, value as unknown);
        }
      };

      mergeIntoStore("", settings as unknown);
      notifySettingsChanged(store.store);
      return true;
    }
  );

  ipcMain.handle("settings:reset", () => {
    store.clear();
    notifySettingsChanged(store.store);
    return true;
  });
}
```

**3.3 IPC handler with event broadcasting** (`src/main/projects-ipc.ts`)

When main process state changes need to notify the renderer, use
`webContents.send()`. Pass the window reference as a getter function to avoid
stale references after window recreation.

```typescript
// src/main/projects-ipc.ts
import { ipcMain, type BrowserWindow } from "electron";
import { projectService } from "./project-service";

export function setupProjectsIPC(getMainWindow: () => BrowserWindow | null) {
  ipcMain.handle(
    "projects:setActive",
    async (_, projectId: string): Promise<void> => {
      const project = await projectService.get(projectId);
      if (!project) throw new Error(`Project ${projectId} not found`);

      await projectService.setActive(projectId);

      // Broadcast to renderer
      const mainWindow = getMainWindow();
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send("project:changed", projectId);
      }
    }
  );
}
```

**Why a getter function?** On macOS, closing all windows does not quit the app.
When the user re-opens, a new `BrowserWindow` is created. A direct reference
would point to the destroyed window. The getter always returns the current one.

**3.4 Simple service-delegating handler** (`src/main/versions-ipc.ts`)

The simplest IPC pattern: each channel maps directly to a service method with no
additional logic.

```typescript
// src/main/versions-ipc.ts
import { ipcMain } from "electron";
import { versionService, type CreateVersionParams } from "./version-service";

export function setupVersionsIPC() {
  ipcMain.handle(
    "versions:create",
    async (_event, payload: CreateVersionParams) =>
      versionService.createVersion(payload)
  );

  ipcMain.handle("versions:list", async (_event, documentId: string) =>
    versionService.getVersions(documentId)
  );

  ipcMain.handle("versions:getActive", async (_event, documentId: string) =>
    versionService.getActiveVersion(documentId)
  );

  ipcMain.handle(
    "versions:switch",
    async (_event, documentId: string, versionId: string) =>
      versionService.switchActiveVersion(documentId, versionId)
  );

  ipcMain.handle(
    "versions:update",
    async (_event, versionId: string, content: string) =>
      versionService.updateVersion({ versionId, content })
  );

  ipcMain.handle(
    "versions:delete",
    async (_event, documentId: string, versionId: string) =>
      versionService.deleteVersion(documentId, versionId)
  );

  ipcMain.handle(
    "versions:rename",
    async (_event, versionId: string, label: string) =>
      versionService.renameVersion(versionId, label)
  );
}
```

### Phase 4: Main Process Registration

All IPC setup functions are called once in `src/main/index.ts` during
`app.whenReady()`. Order matters for dependencies.

**4.1 Register IPC modules** (`src/main/index.ts`)

```typescript
// src/main/index.ts
import { app, BrowserWindow, ipcMain } from "electron";
import { setupSettingsIPC } from "./settings-ipc";
import { setupDocumentsIPC } from "./documents-ipc";
import { setupVersionsIPC } from "./versions-ipc";
import { setupProjectsIPC } from "./projects-ipc";
import { createSettingsStore } from "./settings-store";
import { DocumentExportService } from "./document-export-service";

let mainWindow: BrowserWindow | null = null;

app.whenReady().then(async () => {
  const settingsStore = await createSettingsStore();

  // 1. Settings first (other modules may read settings)
  const notifySettingsChanged = async (settings) => {
    mainWindow?.webContents.send("settings:changed", settings);
  };

  setupSettingsIPC({
    store: settingsStore,
    notifySettingsChanged,
  });

  // 2. Domain modules (order doesn't matter between these)
  const exportService = new DocumentExportService({ settingsStore });
  setupDocumentsIPC({ exportService });
  setupVersionsIPC();

  // 3. Modules needing window reference (pass getter, not direct ref)
  setupProjectsIPC(() => mainWindow);

  // 4. Create window AFTER all IPC handlers are registered
  mainWindow = createMainWindow();
});
```

**CRITICAL ORDERING:**

1. Settings IPC first (other modules may depend on settings)
2. Domain IPC modules (independent of each other)
3. Window-dependent modules (pass getter to avoid stale reference)
4. Create window LAST (ensures all handlers are ready before renderer loads)

**Validate:** Start the app. All `window.*` APIs should be available in the
renderer DevTools console. `window.documents.list()` should return a promise
that resolves with data.

### Phase 5: Pinia Stores as IPC Integration Layer

Pinia stores are the ONLY place in the renderer that calls `window.*` APIs.
Components call store actions. This creates a single audit point for all IPC
usage per domain.

**5.1 Store with loading state and error handling**
(`src/renderer/src/stores/documents.store.ts`)

```typescript
// src/renderer/src/stores/documents.store.ts
import { defineStore } from "pinia";
import { ref, computed } from "vue";
import type { Document } from "@your/database";

export const useDocumentsStore = defineStore("documents", () => {
  // State
  const documents = ref<Document[]>([]);
  const currentDocId = ref<string | null>(null);
  const isLoading = ref(false);

  // Computed
  const currentDocument = computed(() =>
    documents.value.find((doc) => doc.id === currentDocId.value)
  );

  // Actions - always async, always try/catch/finally for loading state
  async function loadDocuments() {
    isLoading.value = true;
    try {
      const result = await window.documents.list();
      documents.value = result;
    } catch (error) {
      console.error("Failed to load documents:", error);
      throw error;
    } finally {
      isLoading.value = false;
    }
  }

  async function createDocument(content = ""): Promise<Document> {
    try {
      const doc = await window.documents.create(content);
      documents.value.unshift(doc); // Optimistic: add to beginning
      currentDocId.value = doc.id;
      return doc;
    } catch (error) {
      console.error("Failed to create document:", error);
      throw error;
    }
  }

  async function updateDocument(id: string, content: string): Promise<void> {
    try {
      await window.documents.update(id, content);
      // Update local state after IPC succeeds
      const doc = documents.value.find((d) => d.id === id);
      if (doc) {
        doc.content = content;
        doc.updatedAt = new Date().toISOString();
      }
    } catch (error) {
      console.error("Failed to update document:", error);
      throw error;
    }
  }

  async function deleteDocument(id: string): Promise<void> {
    try {
      await window.documents.delete(id);
      documents.value = documents.value.filter((d) => d.id !== id);
      if (currentDocId.value === id) {
        currentDocId.value = documents.value[0]?.id ?? null;
      }
    } catch (error) {
      console.error("Failed to delete document:", error);
      throw error;
    }
  }

  return {
    documents,
    currentDocId,
    isLoading,
    currentDocument,
    loadDocuments,
    createDocument,
    updateDocument,
    deleteDocument,
  };
});
```

**Pattern: Optimistic updates.** After `window.documents.create()` succeeds, the
store immediately inserts the document into local state rather than re-fetching
the entire list. This makes the UI feel instant. For operations where the server
generates data (IDs, timestamps), wait for the IPC response before updating
local state.

**5.2 Settings store with event listener**
(`src/renderer/src/stores/settings.store.ts`)

Stores can listen for main-to-renderer events to stay synchronized when settings
change from outside the renderer (e.g., from application menu actions).

```typescript
// src/renderer/src/stores/settings.store.ts
import { defineStore } from "pinia";
import { ref } from "vue";
import type { AppSettings } from "@/types/settings";
import { defaultSettings } from "@/types/settings";

export const useSettingsStore = defineStore("settings", () => {
  const settings = ref<AppSettings>(structuredClone(defaultSettings));
  const isLoading = ref(true);

  const loadSettings = async (): Promise<void> => {
    try {
      isLoading.value = true;
      const loaded = await window.settings.getSettings();
      settings.value = mergeSettings(defaultSettings, loaded);
    } catch (error) {
      console.error("Error loading settings:", error);
      settings.value = structuredClone(defaultSettings);
    } finally {
      isLoading.value = false;
    }
  };

  const updateSettings = async (
    newSettings: Partial<AppSettings>
  ): Promise<boolean> => {
    try {
      const success = await window.settings.updateSettings(newSettings);
      if (success) {
        settings.value = mergeSettings(settings.value, newSettings);
      }
      return success;
    } catch (error) {
      console.error("Error updating settings:", error);
      return false;
    }
  };

  // Listen for settings changes pushed from main process
  const setupSettingsWatcher = (): void => {
    window.settings.onSettingsChanged((newSettings) => {
      settings.value = mergeSettings(defaultSettings, newSettings);
    });
  };

  return {
    settings,
    isLoading,
    loadSettings,
    updateSettings,
    setupSettingsWatcher,
  };
});
```

**Pattern: Push notifications from main.** The `onSettingsChanged` listener is
registered once during app initialization. When settings change in the main
process (e.g., from a menu action or another IPC call), the main process calls
`webContents.send('settings:changed', settings)` and the store receives the
update reactively.

**Validate:** Create a component that calls `documentsStore.loadDocuments()` on
mount. Verify documents appear. Open DevTools and confirm no direct
`window.documents.*` calls exist in component code.

## IPC Naming Convention

Channel names follow the pattern `'domain:operation'`:

| Domain    | Channel                 | Direction        |
| --------- | ----------------------- | ---------------- |
| documents | `documents:create`      | renderer -> main |
| documents | `documents:update`      | renderer -> main |
| documents | `documents:list`        | renderer -> main |
| documents | `document:agentUpdated` | main -> renderer |
| settings  | `settings:get`          | renderer -> main |
| settings  | `settings:update`       | renderer -> main |
| settings  | `settings:changed`      | main -> renderer |
| versions  | `versions:create`       | renderer -> main |
| versions  | `versions:list`         | renderer -> main |
| projects  | `projects:setActive`    | renderer -> main |
| projects  | `project:changed`       | main -> renderer |

**Convention:**

- Renderer-to-main (invoke): `domain:operation` (plural domain, e.g.,
  `documents:create`)
- Main-to-renderer (send): `domain:event` (singular or plural, e.g.,
  `document:agentUpdated`, `settings:changed`)

## Adding a New IPC Endpoint (End-to-End Checklist)

When adding a new domain or operation, follow these steps in order:

### 1. Shared types (if needed)

Add types to `src/shared/types/` that both processes need.

### 2. Service layer

Create `src/main/{domain}-service.ts` with business logic and database
operations.

### 3. IPC handler

Create `src/main/{domain}-ipc.ts`:

```typescript
import { ipcMain } from "electron";
import { myService } from "./my-service";

export function setupMyDomainIPC() {
  ipcMain.handle("myDomain:list", async () => myService.getAll());

  ipcMain.handle("myDomain:create", async (_event, name: string) =>
    myService.create(name)
  );
}
```

### 4. Register in main index

Add to `src/main/index.ts` inside `app.whenReady()`:

```typescript
import { setupMyDomainIPC } from "./my-domain-ipc";
// ...
setupMyDomainIPC();
```

### 5. Preload bridge

Add to `src/preload/index.ts`:

```typescript
contextBridge.exposeInMainWorld("myDomain", {
  list: () => ipcRenderer.invoke("myDomain:list"),
  create: (name: string) => ipcRenderer.invoke("myDomain:create", name),
});
```

### 6. Type declarations

Add to `src/preload/index.d.ts`:

```typescript
declare global {
  interface Window {
    // ... existing declarations
    myDomain: {
      list: () => Promise<MyType[]>;
      create: (name: string) => Promise<MyType>;
    };
  }
}
```

### 7. Pinia store

Create `src/renderer/src/stores/my-domain.store.ts`:

```typescript
export const useMyDomainStore = defineStore("myDomain", () => {
  const items = ref<MyType[]>([]);
  const isLoading = ref(false);

  async function loadItems() {
    isLoading.value = true;
    try {
      items.value = await window.myDomain.list();
    } finally {
      isLoading.value = false;
    }
  }

  async function createItem(name: string) {
    const item = await window.myDomain.create(name);
    items.value.unshift(item);
    return item;
  }

  return { items, isLoading, loadItems, createItem };
});
```

### 8. Wire up in components

Components use the store, never `window.*` directly:

```vue
<script setup>
const store = useMyDomainStore();
onMounted(() => store.loadItems());
</script>
```

## Integration Points

### Application Menu -> Renderer

The application menu (main process) sends events through IPC that the renderer
listens for. These are exposed through a dedicated `menu` namespace in the
preload:

```typescript
// preload
contextBridge.exposeInMainWorld("menu", {
  onOpenPreferences: (callback: () => void) => {
    ipcRenderer.on("menu:openPreferences", () => callback());
  },
  onToggleSidebar: (callback: () => void) => {
    ipcRenderer.on("menu:toggleSidebar", () => callback());
  },
});
```

The renderer registers listeners during app initialization (typically in
`App.vue` or a composable).

### Platform Information

Non-sensitive platform info can be exposed as a static namespace:

```typescript
contextBridge.exposeInMainWorld("electronEnv", {
  platform: process.platform,
});
```

This lets components adapt UI for macOS vs Windows vs Linux without accessing
Node.js.

### Secure Storage

For sensitive data (API keys, auth tokens), expose a dedicated namespace that
wraps Electron's `safeStorage` or OS keychain. Never expose raw `safeStorage` to
the renderer:

```typescript
contextBridge.exposeInMainWorld("secureStorage", {
  setToken: (key: string, value: string) =>
    ipcRenderer.invoke("secure-storage:set", key, value),
  getToken: (key: string) => ipcRenderer.invoke("secure-storage:get", key),
  deleteToken: (key: string) =>
    ipcRenderer.invoke("secure-storage:delete", key),
});
```

## Gotchas & Important Notes

### Register IPC Handlers ONCE Per App Lifecycle

Handlers are registered in `app.whenReady()`, not per window. On macOS, the app
stays alive after all windows close. If you re-register handlers when creating a
new window, you get "handler already registered" errors. Register once, and pass
window references as getters.

### Preload index.d.ts Must Match index.ts Exactly

The type declaration file provides autocomplete in the renderer but is NOT
validated against the implementation at compile time. If the preload exposes
`window.documents.create(content, projectId)` but the `.d.ts` declares
`create(content)`, the renderer will compile but the call will silently pass
`undefined` for `projectId`. Keep these files synchronized manually.

### The `_event` Parameter in IPC Handlers

`ipcMain.handle()` callbacks always receive the IPC event as the first argument.
Name it `_event` or `_` to signal it's unused. The actual call arguments start
at the second parameter. Forgetting this causes off-by-one argument bugs.

### Error Propagation Across IPC Boundary

Errors thrown in `ipcMain.handle()` are serialized and re-thrown as `Error`
objects in the renderer. Custom error classes lose their prototype chain. If you
need structured errors, return an error object instead of throwing:

```typescript
// Instead of: throw new CustomError('message', { code: 'NOT_FOUND' })
// Return:     { success: false, error: { message: 'message', code: 'NOT_FOUND' } }
```

### Window Reference Stale After Recreation (macOS)

On macOS, closing the last window does not quit the app. When `activate` fires
and creates a new window, any direct `BrowserWindow` reference in IPC handlers
will point to the destroyed window. Always use a getter function:

```typescript
// BAD: stale after window recreation
setupProjectsIPC(mainWindow);

// GOOD: always returns current window
setupProjectsIPC(() => mainWindow);
```

### Guard Against Destroyed Windows Before Sending Events

Always check `!mainWindow.isDestroyed()` before calling
`mainWindow.webContents.send()`. Electron does not throw if you send to a
destroyed window, but the event silently disappears.

### `ipcRenderer.invoke()` vs `ipcRenderer.send()`

- `invoke()` returns a Promise (request-response). Use for all renderer-to-main
  calls where you need a result.
- `send()` is fire-and-forget (no response). Rarely needed. Prefer `invoke()`.
- `ipcRenderer.on()` is for main-to-renderer push events only.

### Path Aliases

- `@/` maps to `src/renderer/src/` - use in renderer code only
- `@shared/` maps to `src/shared/` - use in main and preload code
- Do NOT import `@/` paths from main process or vice versa

### No Business Logic in Preload or IPC Handlers

The preload script is a pure pass-through. The IPC handler is a thin bridge.
Business logic (validation, computation, database queries) belongs in
`*-service.ts` files. This keeps the security boundary clear and services
testable without Electron.

## Adding New Features Checklist

When adding a new domain to a project built with this recipe:

1. Create `src/shared/types/{domain}.ts` - Shared types (if needed)
2. Create `src/main/{domain}-service.ts` - Business logic and DB operations
3. Create `src/main/{domain}-ipc.ts` - IPC handlers (`setup{Domain}IPC()`)
4. Register in `src/main/index.ts` - Call setup function in `app.whenReady()`
5. Add to `src/preload/index.ts` -
   `contextBridge.exposeInMainWorld('{domain}', {...})`
6. Add to `src/preload/index.d.ts` - Window type declarations
7. Create `src/renderer/src/stores/{domain}.store.ts` - Pinia store wrapping
   `window.{domain}.*`
8. Use store in components - Never call `window.*` from components directly

## External Documentation

For the latest APIs and configuration beyond what this recipe covers:

- **Electron:** https://www.electronjs.org/docs
- **Electron IPC:** https://www.electronjs.org/docs/latest/tutorial/ipc
- **Vue 3:** https://vuejs.org
- **Pinia:** https://pinia.vuejs.org
- **electron-vite:** https://electron-vite.org
