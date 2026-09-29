# PowerSync Local-First Sync Recipe

## Purpose

Implement bidirectional sync between local SQLite databases (on Electron desktop
and Expo mobile apps) and a PostgreSQL backend using PowerSync. This recipe
captures the integration glue between PowerSync SDK, Drizzle ORM, BetterAuth JWT
authentication, and the PowerSync Service -- the parts that require careful
coordination across multiple platforms and are not obvious from any single
library's documentation.

The core value: users can work fully offline with immediate read/write
performance against a local SQLite database, and their data syncs automatically
to PostgreSQL (and to their other devices) when a network connection is
available.

## When to Use

- Adding cloud sync to an existing local-only SQLite app
- Building an offline-first app that needs multi-device sync
- Setting up PowerSync with Drizzle ORM on Electron or React Native
- Integrating PowerSync authentication with BetterAuth JWT
- Replacing a direct-to-server database with a local-first architecture

## Technology Stack

| Layer           | Technology                         | Version |
| --------------- | ---------------------------------- | ------- |
| Sync Service    | PowerSync (self-hosted or cloud)   | 1.3.8+  |
| Source Database | PostgreSQL                         | 15+     |
| Local Database  | SQLite (via PowerSync SDK)         | -       |
| ORM             | Drizzle ORM (sqlite + pg dialects) | 0.45+   |
| Drizzle Driver  | @powersync/drizzle-driver          | 1.x     |
| Auth            | BetterAuth + JWT plugin            | 1.4+    |
| Desktop SDK     | @powersync/node                    | 1.x     |
| Mobile SDK      | @powersync/react-native            | 1.x     |
| Desktop Runtime | Electron (better-sqlite3 backing)  | -       |
| Mobile Runtime  | Expo / React Native (op-sqlite)    | -       |

## Architecture Overview

### Mental Model

PowerSync acts as a transparent sync layer between PostgreSQL (the source of
truth) and local SQLite databases on each client device. Clients read and write
exclusively against their local SQLite -- PowerSync handles replication in both
directions.

```
Client Devices                     Cloud Infrastructure
==================                 ====================

Desktop (Electron)                 PowerSync Service
 SQLite (local)  ────WebSocket────  Sync Protocol Router
 PowerSync SDK                      Bucket Storage (PG schema)
 Drizzle ORM                              |
                                     Logical Replication
Mobile (Expo)                              |
 SQLite (local)  ────WebSocket────  PostgreSQL (source of truth)
 PowerSync SDK                             |
 Drizzle ORM                         API Backend (Elysia)
                                      BetterAuth + JWT
                                      JWKS endpoint
                                      Upload handler
```

### Key Design Decisions

**PostgreSQL is the source of truth.** PowerSync bucket storage is derived from
PostgreSQL via logical replication and is fully rebuildable. If bucket storage
is lost, PowerSync re-replicates from PostgreSQL. Clients re-download via full
resync. Prioritize PostgreSQL backups; bucket storage backups are optional.

**Two Drizzle schemas, one conceptual model.** Clients use
`drizzle-orm/sqlite-core` and the API uses `drizzle-orm/pg-core`. The schemas
must be manually kept in alignment. Different dialects prevent a single shared
schema definition. Validate alignment with a CI script.

**No foreign key constraints in SQLite.** PowerSync does not support FK
constraints. Referential integrity is enforced in application code (service
layer) instead. This is a deliberate trade-off for sync compatibility.

**Denormalized `ownerId` on every synced table.** PowerSync sync rules filter
rows by `owner_id`. Rather than joining through a parent table, every synced
table carries its own `ownerId` column. This enables simple, efficient sync rule
definitions.

**UUID primary keys everywhere.** PowerSync requires UUID-style string primary
keys. No auto-incrementing integers. All IDs are generated client-side (nanoid
or UUID v4).

**Last-Write-Wins conflict resolution.** PowerSync uses LWW for concurrent
edits. This is acceptable for single-user multi-device scenarios. For
collaborative editing, you would need an additional CRDT or OT layer.

### What This Architecture Avoids

- **No real-time collaborative editing** -- LWW is insufficient for multi-user
  concurrent edits on the same document
- **No composite primary keys** -- PowerSync requires a single UUID `id` column
  as primary key on every table
- **No server-side triggers or computed columns** -- all business logic lives in
  the application layer

## Data Model

### Schema Design Requirements for PowerSync

Every synced table must follow these rules:

1. **Single `text('id').primaryKey()`** -- UUID v4, generated client-side
2. **`ownerId: text('owner_id')`** -- denormalized for sync rule filtering
3. **No foreign key constraints** -- app-enforced referential integrity only
4. **Text timestamps** -- ISO 8601 strings (`text('created_at')`)
5. **Boolean as integer** -- SQLite uses `integer({ mode: 'boolean' })`

Example synced table (SQLite schema):

```typescript
// packages/database/src/schema.ts
import { sqliteTable, text, integer, index } from "drizzle-orm/sqlite-core";

export const documents = sqliteTable(
  "documents",
  {
    id: text("id").primaryKey(), // UUID v4, client-generated
    title: text("title"),
    content: text("content").notNull(),
    ownerId: text("owner_id"), // Denormalized for sync rules
    projectId: text("project_id"), // App-enforced FK (no constraint)
    deviceId: text("device_id").notNull(), // Tracks originating device
    createdAt: text("created_at").notNull(),
    updatedAt: text("updated_at").notNull(),
    deletedAt: text("deleted_at"), // Soft delete
  },
  (table) => [
    index("idx_documents_owner").on(table.ownerId),
    index("idx_documents_deleted").on(table.deletedAt),
  ]
);
```

Equivalent PostgreSQL schema (API side):

```typescript
// apps/api/src/features/core/db.ts
import { pgTable, text, timestamp } from "drizzle-orm/pg-core";

export const documents = pgTable("documents", {
  id: text("id").primaryKey(),
  title: text("title"),
  content: text("content").notNull(),
  ownerId: text("owner_id").notNull(), // NOT NULL on server side
  projectId: text("project_id"),
  deviceId: text("device_id").notNull(),
  createdAt: timestamp("created_at").notNull(),
  updatedAt: timestamp("updated_at").notNull(),
  deletedAt: timestamp("deleted_at"),
});
```

**Critical difference:** `ownerId` is nullable in SQLite but NOT NULL in
PostgreSQL. Clients may create records before sync populates the owner. The API
upload handler sets `ownerId` from the JWT before inserting into PostgreSQL.

### Local-Only vs Synced Tables

Tables that should NOT sync to the backend must be marked `localOnly: true` in
the PowerSync schema. Use local-only for:

- **User preferences** -- device-specific settings
- **Local metadata** -- app state, cache flags
- **Platform-specific tables** -- features only available on one platform

Synced tables are everything else -- the user's actual content data.

## Implementation Process

### Phase 1: Schema and Database Package

The shared schema package is the foundation. Both Desktop and Mobile apps import
table definitions from this package.

**1.1 Define the Drizzle SQLite schema**

Create the shared schema in a monorepo package. Every synced table must have
`id`, `ownerId`, and timestamp columns:

```typescript
// packages/database/src/schema.ts
import {
  sqliteTable,
  text,
  integer,
  index,
  uniqueIndex,
} from "drizzle-orm/sqlite-core";

export const projects = sqliteTable(
  "projects",
  {
    id: text("id").primaryKey(),
    name: text("name").notNull(),
    ownerId: text("owner_id"),
    isDefault: integer("is_default", { mode: "boolean" })
      .notNull()
      .default(false),
    createdAt: text("created_at").notNull(),
    updatedAt: text("updated_at").notNull(),
    deletedAt: text("deleted_at"),
  },
  (table) => [index("idx_projects_owner").on(table.ownerId)]
);
```

Export all tables from the package entry point:

```typescript
// packages/database/src/index.ts
export * as tables from "./schema";
```

**1.2 Configure Drizzle Kit for migrations**

```typescript
// packages/database/drizzle.config.ts
import type { Config } from "drizzle-kit";

export default {
  schema: "./src/schema.ts",
  out: "./drizzle",
  dialect: "sqlite",
  // Use sqlite dialect (not expo) -- generate bundle script
  // handles React Native compatibility separately
} satisfies Config;
```

Run `drizzle-kit generate` to produce migration SQL files. These are used by the
API's PostgreSQL schema (adapted to pg dialect) and optionally for migration
bundles on mobile.

**Validate:** Import the schema package in both Desktop and Mobile apps. Verify
TypeScript compilation succeeds.

### Phase 2: PowerSync Client Setup

Both Desktop and Mobile follow the same pattern: create a `PowerSyncDatabase`,
define which tables are local-only, wrap it with Drizzle, and connect via a
backend connector.

**2.1 Initialize PowerSync with DrizzleAppSchema**

The `DrizzleAppSchema` constructor takes your Drizzle table definitions. By
default, all tables are synced. Override specific tables with `localOnly: true`:

```typescript
import { PowerSyncDatabase } from "@powersync/node"; // Desktop
// OR: import { PowerSyncDatabase } from '@powersync/react-native'; // Mobile
import {
  wrapPowerSyncWithDrizzle,
  DrizzleAppSchema,
} from "@powersync/drizzle-driver";
import { tables } from "@my/database";

const appSchema = new DrizzleAppSchema({
  ...tables,
  // Override local-only tables
  preferences: {
    tableDefinition: tables.preferences,
    options: { localOnly: true },
  },
  localMetadata: {
    tableDefinition: tables.localMetadata,
    options: { localOnly: true },
  },
});

const powerSync = new PowerSyncDatabase({
  schema: appSchema,
  database: {
    dbFilename: "myapp.db",
    // Desktop only: provide a worker for background sync
    // openWorker: openPowerSyncWorker,
  },
});

// Wrap with Drizzle for type-safe query builder
const db = wrapPowerSyncWithDrizzle(powerSync, { schema: tables });
```

**CRITICAL:** PowerSync automatically creates tables from the schema definition.
No client-side SQL migrations are needed for synced tables. PowerSync manages
the SQLite schema lifecycle.

**2.2 Implement the backend connector**

The connector has two methods: `fetchCredentials()` and `uploadData()`.
PowerSync calls these automatically.

```typescript
import type {
  AbstractPowerSyncDatabase,
  PowerSyncBackendConnector,
  PowerSyncCredentials,
} from "@powersync/node"; // or @powersync/react-native

class MyPowerSyncConnector implements PowerSyncBackendConnector {
  async fetchCredentials(): Promise<PowerSyncCredentials | null> {
    // 1. Check if user is authenticated
    // 2. Fetch PowerSync URL from API
    const configResponse = await authenticatedFetch("/api/powersync/config");
    const config = await configResponse.json();

    // 3. Fetch JWT token for PowerSync
    const tokenResponse = await authenticatedFetch("/api/auth/token");
    const { token } = await tokenResponse.json();

    return {
      endpoint: config.powersyncUrl,
      token: token,
    };
  }

  async uploadData(database: AbstractPowerSyncDatabase): Promise<void> {
    const transaction = await database.getNextCrudTransaction();
    if (!transaction) return;

    // Map CRUD entries to upload format
    const ops = transaction.crud.map((entry) => ({
      op: entry.op,
      table: entry.table,
      data: entry.opData,
      id: entry.id,
    }));

    const opId = String(
      transaction.transactionId ?? transaction.crud[0]?.clientId ?? Date.now()
    );

    try {
      const response = await authenticatedFetch("/api/powersync/upload", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          transactions: [{ op_id: opId, ops }],
        }),
      });

      if (!response.ok) {
        const message = await response.text().catch(() => null);
        throw new Error(message || `Upload failed (${response.status})`);
      }
    } catch (error) {
      // Network errors: DON'T complete transaction -- let PowerSync retry
      throw error;
    }

    // ALWAYS complete transaction after successful HTTP response
    // Even if server returned an error in the body, complete to prevent
    // infinite retry loops
    await transaction.complete();
  }
}
```

**CRITICAL ordering in `uploadData`:** Network errors must throw BEFORE
`transaction.complete()` so PowerSync retries when connectivity returns.
Server-side validation errors should still complete the transaction (the server
has processed the request; retrying won't help).

**2.3 Connect to PowerSync**

```typescript
const connector = new MyPowerSyncConnector();
await powerSync.connect(connector);

// Optional: wait for initial sync before showing data
await powerSync.waitForFirstSync();
```

**Validate:** Start the app, sign in, verify that synced tables populate from
the server. Create a record locally, verify it appears in PostgreSQL.

### Phase 3: API Backend -- JWT and Upload Endpoint

The API provides three integration points for PowerSync:

1. **JWKS endpoint** -- PowerSync verifies JWT signatures
2. **Token endpoint** -- clients fetch JWTs for PowerSync auth
3. **Upload endpoint** -- receives client writes and applies to PostgreSQL

**3.1 Configure BetterAuth with JWT plugin**

PowerSync requires RS256 JWTs verified via JWKS. BetterAuth's JWT plugin
generates these:

```typescript
import { betterAuth } from "better-auth";
import { jwt } from "better-auth/plugins";

export const auth = betterAuth({
  // ... other config ...
  plugins: [
    jwt({
      jwks: {
        keyPairConfig: {
          alg: "RS256", // PowerSync requires RS256
        },
      },
    }),
  ],
});
```

This automatically exposes:

- `GET /api/auth/jwks` -- JWKS public keys (PowerSync fetches these)
- `GET /api/auth/token` -- JWT with `sub` claim = user ID

**3.2 Create the PowerSync config endpoint**

```typescript
// GET /api/powersync/config
app.get("/config", async ({ user }) => {
  return {
    powersyncUrl: env.POWERSYNC_URL,
    userId: user.id,
  };
});
```

**3.3 Create the upload endpoint**

The upload endpoint receives CRUD operations from PowerSync clients and applies
them to PostgreSQL. Key responsibilities:

- Validate `ownerId` matches the authenticated user
- Set `ownerId` from JWT (clients may send null)
- Handle snake_case to camelCase conversion (PowerSync sends snake_case column
  names, Drizzle uses camelCase)
- Convert timestamp formats (SQLite text to PostgreSQL timestamp)
- Use `onConflictDoUpdate` for PUT operations (upsert pattern)

```typescript
app.put("/upload", async ({ user, body }) => {
  const userId = user.id;

  for (const transaction of body.transactions) {
    await db.transaction(async (tx) => {
      for (const op of transaction.ops) {
        // Inject ownerId from JWT -- never trust client-provided ownerId
        const data = op.data ? { ...op.data, ownerId: userId } : undefined;

        switch (op.op) {
          case "PUT":
            await tx
              .insert(tableRef)
              .values({ id: op.id, ...sanitizedData })
              .onConflictDoUpdate({ target: tableRef.id, set: sanitizedData });
            break;
          case "PATCH":
            await tx
              .update(tableRef)
              .set(sanitizedData)
              .where(and(eq(tableRef.id, op.id), eq(tableRef.ownerId, userId)));
            break;
          case "DELETE":
            // Soft delete for content tables
            await tx
              .update(tableRef)
              .set({ deletedAt: new Date() })
              .where(and(eq(tableRef.id, op.id), eq(tableRef.ownerId, userId)));
            break;
        }
      }
    });
  }
});
```

**CRITICAL:** Always filter by `ownerId = userId` on PATCH and DELETE
operations. This is defense-in-depth -- sync rules also filter by owner, but the
upload endpoint must independently verify ownership.

**Validate:** Create a record on a client, verify it appears in PostgreSQL with
the correct `ownerId`. Modify the record, verify the update propagates.

### Phase 4: PowerSync Service Configuration

The PowerSync Service runs as a Docker container and connects to PostgreSQL via
logical replication.

**4.1 Configure PostgreSQL for logical replication**

```sql
ALTER SYSTEM SET wal_level = 'logical';
ALTER SYSTEM SET max_wal_senders = 10;
ALTER SYSTEM SET max_replication_slots = 10;

-- Limit WAL retention to prevent disk exhaustion
ALTER SYSTEM SET max_slot_wal_keep_size = '1GB';

-- Create publication for PowerSync
CREATE PUBLICATION powersync FOR ALL TABLES;
```

Restart PostgreSQL after changing `wal_level`.

**4.2 Configure PowerSync service**

```yaml
# powersync.yaml
replication:
  connections:
    - type: postgresql
      uri: !env PS_DATABASE_URL
      sslmode: disable

# Use PostgreSQL for bucket storage (consolidated infrastructure)
storage:
  type: postgresql
  uri: !env PS_STORAGE_URL
  sslmode: disable

# JWT verification via JWKS
client_auth:
  jwks_uri: !env PS_JWKS_URI
  audience:
    - http://localhost:3011 # Must match BetterAuth base URL

port: 8080

sync_rules:
  path: /config/sync_rules.yaml
```

**4.3 Define sync rules**

Sync rules determine which rows each user receives. Every query filters by
`owner_id`:

```yaml
# sync_rules.yaml
bucket_definitions:
  user_data:
    parameters: SELECT request.user_id() as user_id
    data:
      - SELECT * FROM projects WHERE owner_id = bucket.user_id
      - SELECT * FROM documents WHERE owner_id = bucket.user_id
      - SELECT * FROM document_versions WHERE owner_id = bucket.user_id
      - SELECT * FROM groups WHERE owner_id = bucket.user_id
      - SELECT * FROM group_hierarchy WHERE owner_id = bucket.user_id
      - SELECT * FROM document_groups WHERE owner_id = bucket.user_id
```

`request.user_id()` extracts the `sub` claim from the JWT. The `bucket.user_id`
parameter is then used to filter each table.

**4.4 Docker Compose setup**

```yaml
services:
  powersync:
    image: journeyapps/powersync-service:latest
    ports:
      - "8080:8080"
    environment:
      PS_DATABASE_URL: postgresql://user:pass@postgres:5432/mydb
      PS_STORAGE_URL: postgresql://user:pass@postgres:5432/mydb
      PS_JWKS_URI: http://host.docker.internal:3011/api/auth/jwks
    volumes:
      - ./powersync-config/powersync.yaml:/config/powersync.yaml
      - ./powersync-config/sync_rules.yaml:/config/sync_rules.yaml
    depends_on:
      - postgres
```

**CRITICAL:** The `PS_JWKS_URI` must be reachable from inside the Docker
container. Use `host.docker.internal` for macOS/Windows development. For Linux,
use the host's IP or Docker network.

**Validate:** Start the Docker stack. Check PowerSync logs for successful
connection to PostgreSQL and JWKS endpoint. Verify sync works end-to-end.

### Phase 5: Multi-Platform Considerations

**5.1 Electron Desktop**

- SDK: `@powersync/node` (uses better-sqlite3 under the hood)
- Requires a Web Worker for background sync operations
- Credential storage via `electron-store` (or `safeStorage` for production)
- Sync control via IPC -- renderer sends enable/disable commands to main process
- Main process manages the PowerSync connection lifecycle
- Status updates emitted to renderer via `webContents.send()`

```typescript
// Worker setup for Electron
import { Worker } from "worker_threads";
const powerSyncWorkerPath = path.join(__dirname, "powersync-worker.js");

const powerSync = new PowerSyncDatabase({
  schema: appSchema,
  database: {
    dbFilename: getDatabaseFilePath(),
    openWorker: (workerPath, options) =>
      new Worker(powerSyncWorkerPath, options),
  },
});
```

**5.2 Expo / React Native Mobile**

- SDK: `@powersync/react-native` (uses op-sqlite driver)
- Database filename is relative (no absolute paths)
- Sync context provider wraps the React tree
- Network state monitoring via `@react-native-community/netinfo`
- Account switching requires `disconnectAndClear()` then reinitialize

```typescript
// React context for sync state management
function SyncProvider({ children }) {
  const [status, setStatus] = useState('idle');

  useEffect(() => {
    const db = getRawDatabase();
    const dispose = db.registerListener({
      statusChanged: (nextStatus) => {
        // Map PowerSync status to app-level status
        setStatus(mapStatus(nextStatus));
      },
    });
    return dispose;
  }, []);

  return <SyncContext.Provider value={{ status }}>{children}</SyncContext.Provider>;
}
```

### Phase 6: Account Switching and Database Reset

When a user signs out or switches accounts, the local database must be handled
carefully to prevent data leakage between accounts.

**6.1 Account switch detection**

Track the `ownerUserId` in persistent storage. On sign-in, compare with stored
value:

```typescript
const shouldClear = Boolean(
  storedOwnerUserId && storedOwnerUserId !== newUserId
);

if (shouldClear) {
  await powerSync.disconnectAndClear(); // Wipes all synced data
  // Local-only tables are preserved
}
```

**6.2 Database version tracking (Mobile)**

After clearing and reconnecting, increment a `databaseVersion` counter.
Components that cache query results watch this value to know when to refetch:

```typescript
const [databaseVersion, setDatabaseVersion] = useState(0);

if (shouldClear) {
  await disconnectAndClearDatabase();
  setDatabaseVersion((v) => v + 1);
}
```

**Validate:** Sign in as User A, create data. Sign out, sign in as User B.
Verify User A's data is not visible. Sign back in as User A, verify data resyncs
from server.

## Integration Points

### Authentication Flow

1. User authenticates with BetterAuth (email/password, OAuth, etc.)
2. Client stores session cookie or bearer token
3. Client calls `GET /api/auth/token` to obtain a JWT
4. JWT contains `sub` (user ID) and `aud` (audience) claims
5. PowerSync connector provides JWT to PowerSync Service
6. PowerSync Service validates JWT signature via JWKS endpoint
7. Sync rules extract `user_id` from JWT `sub` claim

### Write Path (Client to Server)

1. User writes to local SQLite (immediate, offline-capable)
2. PowerSync SDK queues write in local `ps_crud` table
3. When online, connector's `uploadData()` sends batch to API
4. API validates ownership, sanitizes data, writes to PostgreSQL
5. PostgreSQL logical replication streams change to PowerSync Service
6. PowerSync updates bucket storage, increments checksums
7. Other devices detect checksum change, download updates

### Read Path (Server to Client)

1. PostgreSQL change emitted via logical replication
2. PowerSync Service applies sync rules (per-user filtering)
3. Filtered data stored in bucket storage
4. Client compares local checksums with server
5. Client downloads changed buckets as delta updates
6. PowerSync SDK applies updates to local SQLite
7. App UI reactively updates via Drizzle query subscriptions

### Reactive Queries

PowerSync provides reactive query subscriptions. Use the Drizzle query builder
for type safety:

```typescript
const docs = await db
  .select()
  .from(documents)
  .where(eq(documents.projectId, projectId));
```

For React Native, `usePowerSyncQuery` provides automatic re-rendering on data
changes.

## Settings / Configuration

### Environment Variables

| Variable             | Purpose                                  | Example                                             |
| -------------------- | ---------------------------------------- | --------------------------------------------------- |
| `POWERSYNC_URL`      | PowerSync Service WebSocket URL          | `http://localhost:8080`                             |
| `PS_DATABASE_URL`    | PostgreSQL connection for replication    | `postgresql://user:pass@host:5432/db`               |
| `PS_STORAGE_URL`     | PostgreSQL connection for bucket storage | Same as PS_DATABASE_URL (same DB, different schema) |
| `PS_JWKS_URI`        | API JWKS endpoint for JWT verification   | `http://host.docker.internal:3011/api/auth/jwks`    |
| `BETTER_AUTH_SECRET` | BetterAuth secret for JWT signing        | (random string)                                     |

### PowerSync Service Config

| Setting                   | Purpose                                 | Value                          |
| ------------------------- | --------------------------------------- | ------------------------------ |
| `client_auth.jwks_uri`    | Where to fetch JWT public keys          | API /api/auth/jwks endpoint    |
| `client_auth.audience`    | Expected JWT audience claim             | Must match BetterAuth base URL |
| `storage.type`            | Bucket storage backend                  | `postgresql` (recommended)     |
| `replication.connections` | Source database for logical replication | PostgreSQL connection URI      |

## Gotchas & Important Notes

### Schema Alignment is Manual and Error-Prone

SQLite and PostgreSQL schemas use different Drizzle dialects and must be kept in
sync manually. Create a validation script that compares table names, column
names, and types across both schemas. Run it in CI. Drift between schemas causes
silent sync failures.

### Owner ID Nullability Mismatch

Clients create records with `ownerId: null` (the client may not know the user
ID). The API upload handler MUST set `ownerId` from the JWT `sub` claim before
inserting into PostgreSQL. If you forget this, sync rules filter out the record
(no `owner_id` match) and the data "disappears."

### Snake Case vs Camel Case

PowerSync sends column names in snake_case (matching SQLite column names), but
Drizzle's TypeScript API uses camelCase. The upload handler must handle both
formats. Use a sanitization function that checks for both:

```typescript
const deviceId = "device_id" in data ? data.device_id : data.deviceId;
```

### Timestamp Format Conversion

SQLite stores timestamps as ISO 8601 text strings. PostgreSQL uses native
`timestamp` columns. The upload handler must convert between formats. Pay
attention to Unix timestamps vs ISO strings, and seconds vs milliseconds:

```typescript
// Timestamps < 10 billion are likely in seconds, not milliseconds
const timestamp = Math.abs(value) < 10_000_000_000 ? value * 1000 : value;
return new Date(timestamp);
```

### Boolean Conversion

SQLite stores booleans as integers (0/1). PostgreSQL uses native booleans. The
upload handler must convert: `Boolean(value)`.

### JWT Audience Must Match

PowerSync validates the JWT `aud` (audience) claim against its configured
`client_auth.audience`. This MUST match the BetterAuth base URL exactly
(including protocol and port). A mismatch causes all sync connections to be
rejected with cryptic "unauthorized" errors.

### Transaction Completion in uploadData

In the connector's `uploadData`, always call `transaction.complete()` after a
successful HTTP response, even if the response body contains an error. If you
only call `complete()` on full success, server-side validation errors cause
infinite retry loops (the transaction is never marked as completed, so PowerSync
keeps calling `uploadData` with the same transaction).

Only skip `complete()` for actual network failures (fetch throws), where a retry
might succeed.

### Replication Slot Management

PostgreSQL replication slots grow indefinitely if PowerSync disconnects. Set
`max_slot_wal_keep_size` to prevent disk exhaustion. Monitor
`pg_replication_slots` for slot status.

### Account Switching Requires Database Clear

When a user switches accounts, you MUST call `disconnectAndClear()` to wipe
synced data before reconnecting with the new user's credentials. Otherwise, the
previous user's data remains in the local SQLite database and may be visible to
the new user.

### PowerSync Stale Query Race Condition

When using reactive queries (`usePowerSyncQuery`) with async post-processing,
beware of stale data. PowerSync returns cached results immediately when query
parameters change, then updates asynchronously. If your async processing
(additional DB calls, API calls) takes longer than the query refresh, stale
results can overwrite correct results. Use a generation counter or abort
controller to discard stale async work.

### No Composite Primary Keys

PowerSync requires every table to have a single `text('id').primaryKey()`
column. If your data model naturally uses composite keys (e.g., a many-to-many
join table), add a synthetic UUID `id` column as the primary key and enforce
uniqueness via a separate unique index on the composite columns.
