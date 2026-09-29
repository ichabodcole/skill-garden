# Soft Delete with Restore Recipe

## Purpose

Implement a deletion pattern where records are never physically removed from the
database. Instead, a nullable `deletedAt` timestamp marks records as deleted,
allowing restore and auditability. This is the "recycle bin" pattern for data --
records move to a logical trash state rather than being destroyed.

This recipe is technology-agnostic at the architecture level. The concepts, data
model, and service API work with any database (SQL, NoSQL, local SQLite, cloud
Postgres) and any frontend framework.

## When to Use

- Any app where users create content they might accidentally delete
- Apps with cloud sync where permanent deletes cause irreversible data loss
- Systems that need an audit trail of what was deleted and when
- Multi-device apps where a delete on one device should be recoverable on
  another
- Apps planning a future "trash" or "recently deleted" UI feature
- When you need cascading deletes that are reversible (delete a folder and all
  its contents, then undo the whole thing)

## Architecture Overview

### Core Concept: Logical Deletion via Timestamp

Every deletable entity has a nullable `deletedAt` column. When `deletedAt` is
`NULL`, the record is active. When it contains a timestamp, the record is
logically deleted.

```
Document: "Meeting Notes"
  deletedAt: NULL           --> Active, visible in all queries

Document: "Old Draft"
  deletedAt: 2026-01-15...  --> Soft-deleted, hidden from normal queries
                                but still in the database, restorable
```

**Key properties:**

- **Convention, not mechanism.** Soft delete is enforced by application code,
  not by the database engine. Every query must explicitly filter on `deletedAt`.
- **Timestamp, not boolean.** Using a timestamp rather than a boolean flag
  provides audit information (when was it deleted?) and enables retention
  policies (delete records older than 90 days).
- **Read queries are the enforcement point.** The delete operation is trivially
  simple (`SET deletedAt = NOW()`). The complexity is in consistently filtering
  deleted records out of every read query.

### Why This Design?

**Problem it solves:** "I accidentally deleted my document and want it back" or
"I deleted a folder but need one of the documents that was inside it."

**What it avoids:**

- **Not a full versioning system.** Soft delete tracks deletion state, not
  content history. Use the Document Versioning recipe for content snapshots.
- **Not a temporal database.** Records don't track their full edit history, only
  whether they're currently deleted.
- **Not a database-level feature.** Some databases offer temporal tables or
  soft-delete plugins. This recipe uses application-level logic for portability.

**Trade-offs:**

- Every read query must filter `deletedAt IS NULL` = risk of forgetting, leaking
  deleted data
- Unique constraints must account for soft-deleted records (more complex)
- Database grows over time without a purge strategy
- Join tables and relationships need careful thought around cascading

---

## Data Model

### Column Definition

Add to every deletable entity:

| Column      | Type           | Constraints | Purpose                      |
| ----------- | -------------- | ----------- | ---------------------------- |
| `deletedAt` | timestamp/text | nullable    | NULL = active, set = deleted |

**Use ISO 8601 text** (e.g., `"2026-01-15T10:30:00.000Z"`) if your database
stores timestamps as text (common with SQLite). Use native `TIMESTAMPTZ` for
PostgreSQL.

### Schema Example (SQL-like notation)

```sql
CREATE TABLE documents (
  id          TEXT PRIMARY KEY,
  title       TEXT,
  content     TEXT NOT NULL,
  project_id  TEXT,             -- FK to projects
  created_at  TEXT NOT NULL,    -- ISO 8601
  updated_at  TEXT NOT NULL,    -- ISO 8601
  deleted_at  TEXT              -- ISO 8601, NULL = active
);

CREATE TABLE groups (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  project_id  TEXT,             -- FK to projects
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  deleted_at  TEXT              -- NULL = active
);

CREATE TABLE projects (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  deleted_at  TEXT              -- NULL = active
);
```

### Required Indexes

Every table with `deletedAt` needs an index on that column:

```sql
CREATE INDEX idx_documents_deleted ON documents(deleted_at);
CREATE INDEX idx_groups_deleted    ON groups(deleted_at);
CREATE INDEX idx_projects_deleted  ON projects(deleted_at);
```

**Why:** Most queries filter `WHERE deleted_at IS NULL`. Without an index, the
database scans every row. The index lets it quickly find active records.

**Composite indexes for common query patterns:**

```sql
-- "All active documents in a project, sorted by update time"
CREATE INDEX idx_documents_project_active
  ON documents(project_id, deleted_at, updated_at);

-- "All active groups in a project"
CREATE INDEX idx_groups_project_active
  ON groups(project_id, deleted_at);
```

### Entities That Should NOT Be Soft-Deleted

Not every table needs `deletedAt`. Skip it for:

- **Join/link tables** (e.g., `document_groups`, `group_hierarchy`) -- these
  represent relationships, not user-visible data. When a parent is soft-deleted,
  the links can remain; queries filter on the parent's `deletedAt`.
- **Immutable records** (e.g., `document_versions`) -- version snapshots are
  never independently deleted. They follow their parent document.
- **Configuration/metadata** tables (e.g., `preferences`, `local_metadata`) --
  typically overwritten, not deleted.

---

## Service Layer

### Service API

Each deletable entity's service exposes these operations:

```
EntityService
  softDelete(id)               --> void
  hardDelete(id)               --> void    (optional, for cleanup/purge)
  restore(id)                  --> void    (set deletedAt back to NULL)

  -- All read operations implicitly filter deletedAt IS NULL:
  get(id)                      --> Entity | null
  list()                       --> Entity[]
  listDeleted()                --> Entity[]  (for trash UI)
```

### Operation Details

#### `softDelete(id)`

The primary delete operation. Sets `deletedAt` to the current timestamp.

**Logic:**

1. Get current timestamp
2. `UPDATE entity SET deleted_at = NOW() WHERE id = :id`
3. Return (no error if already deleted -- idempotent)

**Important:** Do NOT update `updatedAt` during soft delete. The `updatedAt`
should reflect the last content edit, and `deletedAt` tracks the deletion time
separately. This lets you sort "recently deleted" items by when they were
deleted, and sort active items by when they were last edited.

#### `restore(id)`

Reverses a soft delete. Sets `deletedAt` back to `NULL`.

**Logic:**

1. `UPDATE entity SET deleted_at = NULL WHERE id = :id`
2. Return

**Important:** Restore only clears `deletedAt`. It does not modify any other
fields. The record returns to exactly the state it was in before deletion.

#### `hardDelete(id)`

Permanently removes the record from the database. Use sparingly.

**Logic:**

1. `DELETE FROM entity WHERE id = :id`
2. Cascade delete related records (versions, links, etc.)

**When to use:**

- Scheduled purge job (delete records soft-deleted more than N days ago)
- Admin cleanup tools
- GDPR/data-deletion compliance requests
- Testing and development

**Important:** Hard delete should NOT be exposed as a default user action. The
default delete operation should always be soft delete. Hard delete is a
maintenance/admin operation.

#### Read Operations (Filtering)

**Every read query must include `WHERE deleted_at IS NULL`** unless you are
specifically querying for deleted records (trash view).

```sql
-- List active documents
SELECT * FROM documents WHERE deleted_at IS NULL ORDER BY updated_at DESC;

-- Get a specific document (include deleted check for safety)
SELECT * FROM documents WHERE id = :id AND deleted_at IS NULL LIMIT 1;

-- Get a document regardless of deletion state (for restore UI, admin)
SELECT * FROM documents WHERE id = :id LIMIT 1;

-- List deleted documents (trash view)
SELECT * FROM documents WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC;
```

**Exception: Get by ID for internal operations.** Some operations (restore,
cascade delete) need to find records regardless of deletion state. In those
cases, omit the `deletedAt` filter, but document why.

---

## Cascading Soft Deletes

When a parent entity is soft-deleted, what happens to its children? This is the
most architecturally significant decision in the soft delete pattern.

### Strategy 1: Cascade Delete Children (Recommended for containment hierarchies)

When a parent is deleted, all children are also soft-deleted with the same
timestamp.

```
Delete Project "Work"
  |-- Soft-delete Project "Work"              (deleted_at = NOW)
  |-- Soft-delete Group "Meeting Notes"       (deleted_at = NOW)
  |-- Soft-delete Group "Projects"            (deleted_at = NOW)
  |-- Soft-delete Document "Q1 Review"        (deleted_at = NOW)
  |-- Soft-delete Document "Budget"           (deleted_at = NOW)
  ...
```

**When to use:** When children have no meaning outside their parent. Deleting a
project should delete its folders and documents.

**Implementation pattern (for a project with nested groups and documents):**

```
deleteProjectAndContents(projectId):
  timestamp = NOW()

  Transaction:
    1. Find all groups WHERE project_id = projectId AND deleted_at IS NULL
    2. Find all documents in those groups (via join tables)
    3. SET deleted_at = timestamp on all documents
    4. SET deleted_at = timestamp on all groups
    5. SET deleted_at = timestamp on the project
```

**Key detail:** Use the SAME timestamp for all records in the cascade. This
makes it possible to identify "everything deleted as part of this operation" and
enables batch restore.

### Strategy 2: Promote Children (Alternative for reorganization)

When a parent is deleted, children are moved to the grandparent level rather
than being deleted.

```
Delete Group "Subproject A" (parent: "Projects")
  |-- Soft-delete Group "Subproject A"
  |-- Move child groups to "Projects"
  |-- Move child documents to "Projects"
```

**When to use:** When the user wants to remove organizational structure without
losing content. "Delete this folder but keep its contents."

**Implementation pattern:**

```
deleteGroupOnly(groupId):
  timestamp = NOW()

  Transaction:
    1. Find parent of this group (from hierarchy table)
    2. If parent exists:
       a. Reparent all child groups to parent
       b. Move all documents to parent group
    3. If no parent (root-level):
       a. Child groups become root-level
       b. Documents become ungrouped
    4. Remove this group from hierarchy
    5. SET deleted_at = timestamp on this group only
```

### Strategy 3: Offer Both Options

Present the user with a choice:

- **"Delete group only"** (default, safe) -- promotes contents
- **"Delete group and contents"** -- cascading soft delete

This is the recommended approach for folder/group deletion because it covers
both use cases and defaults to the non-destructive option.

### Cascade Restore

If you cascade-delete, you should support cascade-restore:

```
restoreProject(projectId):
  Transaction:
    1. Get the project's deletedAt timestamp
    2. Find all groups WHERE project_id = projectId
       AND deleted_at = project's deletedAt  (same batch)
    3. Find all documents in those groups
       AND deleted_at = project's deletedAt  (same batch)
    4. SET deleted_at = NULL on all matching documents
    5. SET deleted_at = NULL on all matching groups
    6. SET deleted_at = NULL on the project
```

**Why match on the same timestamp:** If a document was individually deleted
before the project cascade, it should NOT be restored when the project is
restored. Matching on the cascade timestamp ensures only batch-deleted items are
restored together.

---

## Unique Constraints with Soft Deletes

Soft deletes create a subtle problem with unique constraints.

### The Problem

Suppose you have a unique constraint: one group name per project.

```sql
UNIQUE (project_id, name)
```

User creates "Meeting Notes", then soft-deletes it. Now they try to create a new
"Meeting Notes" -- the unique constraint blocks it because the soft-deleted
record still exists.

### Solutions

**Option A: Exclude deleted records from the constraint (recommended)**

Use a partial/filtered index (PostgreSQL, SQLite 3.9+):

```sql
CREATE UNIQUE INDEX idx_groups_unique_name
  ON groups(project_id, name)
  WHERE deleted_at IS NULL;
```

This only enforces uniqueness among active records. Deleted records are ignored.

**Option B: Include deletedAt in the constraint**

```sql
UNIQUE (project_id, name, deleted_at)
```

This allows multiple deleted records with the same name (since they have
different `deletedAt` values) and one active record (with `NULL`). However, some
databases treat `NULL` specially in unique constraints, so test this carefully.

**Option C: Application-level enforcement**

Skip the database constraint entirely and check in application code:

```
Before insert:
  Check if active record with same name exists (WHERE deleted_at IS NULL)
  If exists, throw DuplicateNameError
```

This is simpler but risks race conditions without proper locking.

**Recommendation:** Option A (partial index) if your database supports it.
Option C as fallback.

---

## Sync Considerations

In apps with cloud sync (PowerSync, CRDTs, Firebase, etc.), soft delete
interacts with the sync layer.

### Sync Rules Must Filter deletedAt

If your sync layer uses row-level rules to determine what data each client
receives, ensure those rules filter on `deletedAt`:

```sql
-- PowerSync sync rule example
SELECT * FROM documents
WHERE owner_id = :user_id AND deleted_at IS NULL
```

Without this filter, deleted records continue syncing to clients, wasting
bandwidth and confusing the UI.

### Server-Side Delete Handling

When the sync layer receives a "DELETE" operation from a client:

```
handleDelete(table, id, userId):
  -- Convert DELETE into soft delete on the server
  UPDATE table SET deleted_at = NOW()
  WHERE id = :id AND owner_id = :userId
```

**Exception:** Some tables genuinely need hard deletes on the server (join
tables, ephemeral records). Handle these on a per-table basis.

### Conflict Resolution

Soft delete simplifies sync conflict resolution:

- **Delete + Edit conflict:** If Device A deletes a document while Device B
  edits it, the soft-deleted record can be restored with Device B's edits
  intact. With hard delete, Device B's edits would be lost.
- **Delete + Delete:** Idempotent -- both devices set `deletedAt`, last write
  wins (both result in the record being deleted).

### Application-Enforced Cascades (No FK Constraints)

Many sync systems (PowerSync, etc.) don't support foreign key constraints.
Cascading deletes must be enforced in application code:

```
-- Instead of: ON DELETE CASCADE
-- Do this in your service layer:

deleteProject(projectId):
  1. Soft-delete all groups WHERE project_id = projectId
  2. Soft-delete all documents in those groups
  3. Soft-delete the project
```

Document every cascade relationship with comments in your schema:

```sql
project_id TEXT,  -- App-enforced: cascade delete
```

---

## Permanent Deletion (Purge Strategy)

Soft-deleted records accumulate over time. You need a strategy for eventual
cleanup.

### Manual Purge (Simplest)

Don't auto-purge. Let soft-deleted records accumulate until an admin explicitly
runs a cleanup job.

**When to use:** Small apps, apps with low deletion rates, early-stage products
where simplicity matters.

### Scheduled Purge with Retention Period

Run a periodic job that permanently deletes records older than a retention
window:

```
purgeDeletedRecords(retentionDays = 90):
  cutoff = NOW() - retentionDays days

  -- Delete in dependency order (children before parents)
  DELETE FROM document_versions
    WHERE document_id IN (
      SELECT id FROM documents WHERE deleted_at < cutoff
    )
  DELETE FROM document_groups
    WHERE document_id IN (
      SELECT id FROM documents WHERE deleted_at < cutoff
    )
  DELETE FROM documents WHERE deleted_at < cutoff
  DELETE FROM groups WHERE deleted_at < cutoff
  DELETE FROM projects WHERE deleted_at < cutoff
```

**Key details:**

- **Respect dependency order.** Delete children (versions, links) before parents
  (documents, groups).
- **Use a generous retention period.** 30-90 days is typical. Users rarely need
  to restore something deleted months ago.
- **Run during off-peak hours.** Purge jobs can be expensive on large datasets.
- **Log what was purged.** Keep an audit record of permanently deleted items.

### User-Initiated Purge

Let users permanently delete items from their trash:

- "Empty Trash" button that hard-deletes all soft-deleted records
- Per-item "Delete Permanently" in the trash view
- Confirmation dialog: "This cannot be undone"

---

## UI Patterns

### Trash / Recently Deleted View

A dedicated view showing all soft-deleted items:

**Features:**

- List items sorted by `deletedAt` descending (most recently deleted first)
- Show original title/name and deletion date
- "Restore" action per item
- "Delete Permanently" action per item (optional)
- "Empty Trash" bulk action (optional)
- Count badge on trash icon showing number of items

**Sorting:** Sort by `deletedAt`, not `updatedAt`. Users want to find "that
thing I just deleted," not "that thing I last edited."

### Delete Action

The user-facing delete action should always be soft delete:

- Button/menu label: "Delete" or "Move to Trash"
- No confirmation dialog for soft delete (it's reversible)
- Toast notification: "Document deleted" with "Undo" action
- Undo action calls `restore(id)` immediately

**Confirmation for cascading deletes:** When deleting a container (folder,
project) that has children, show a confirmation dialog explaining what will be
affected: "This folder contains 12 documents. Delete folder and contents?"

### Undo via Toast

The simplest restore UX is a toast notification with an undo action:

```
[Document deleted]                    [Undo]
```

The toast appears for 5-10 seconds. Clicking "Undo" calls `restore(id)`. If the
toast dismisses, the item stays soft-deleted (recoverable from trash).

### API Design

For APIs that expose delete operations:

```
DELETE /api/documents/:id              -- Soft delete (default)
DELETE /api/documents/:id?permanent=true  -- Hard delete (admin only)
POST   /api/documents/:id/restore      -- Restore from soft delete
```

Or if you prefer explicit routes:

```
POST   /api/documents/:id/trash        -- Soft delete
DELETE /api/documents/:id              -- Hard delete
POST   /api/documents/:id/restore      -- Restore
```

**Recommendation:** Make the default `DELETE` do soft delete. Require an
explicit flag or separate endpoint for hard delete. This prevents accidental
permanent deletion from API callers.

---

## Implementation Phases

### Phase 1: Schema & Indexes

1. Add `deleted_at` (nullable timestamp) column to every deletable entity
2. Create indexes on `deleted_at` for each table
3. Run migration
4. Add composite indexes for common query patterns

**Validate:** Column exists, indexes exist, existing records have
`deleted_at = NULL`.

### Phase 2: Service Layer - Soft Delete & Filter

1. Implement `softDelete(id)` on each entity service
2. Add `WHERE deleted_at IS NULL` to ALL existing read queries
3. Audit every query in every service to ensure filtering is applied
4. Implement `hardDelete(id)` for admin/cleanup use

**Validate:** Soft-delete a record, verify it no longer appears in list queries,
verify it still exists in the database.

**CRITICAL:** This is the phase where bugs hide. Grep your entire codebase for
every query on each table and verify the `deletedAt` filter is present. Missing
a single query means deleted records leak into the UI.

### Phase 3: Cascading Deletes

1. Implement cascading soft delete for parent-child relationships
2. For containers (projects, groups), implement both "delete only" and "delete
   with contents" variants
3. Use the same timestamp for all records in a cascade operation
4. Wrap cascade operations in transactions

**Validate:** Delete a project, verify all child groups and documents are
soft-deleted. Delete a group only, verify children are promoted. Delete a group
with contents, verify all nested content is soft-deleted.

### Phase 4: Restore

1. Implement `restore(id)` that sets `deleted_at = NULL`
2. Implement cascade restore for containers (match on cascade timestamp)
3. Add "Undo" toast after delete operations
4. Wire undo to restore

**Validate:** Soft-delete a document, click undo, verify it reappears. Delete a
project with cascading, restore it, verify children are also restored.

### Phase 5: Trash UI (Optional)

1. Add a "Trash" or "Recently Deleted" view
2. Query for records where `deleted_at IS NOT NULL`
3. Add per-item restore and permanent delete actions
4. Add "Empty Trash" bulk action
5. Show deletion date and original location

**Validate:** Soft-delete several items, open trash, verify they appear. Restore
one, verify it leaves trash. Permanently delete one, verify it's gone.

### Phase 6: Purge Strategy (Optional)

1. Implement a purge function that hard-deletes records older than N days
2. Respect dependency order (children before parents)
3. Schedule the purge job (cron, background task, etc.)
4. Add logging for audit trail

**Validate:** Soft-delete records with old timestamps, run purge, verify they're
permanently removed. Verify recently-deleted records are not purged.

---

## Adapting to Different Tech Stacks

### Database Adapters

**SQLite (local-first apps):**

- Use `TEXT` for `deleted_at` (ISO 8601 strings)
- Partial indexes supported in SQLite 3.9+ (`WHERE deleted_at IS NULL`)
- No FK constraints in many sync setups -- enforce cascades in application code
- Example: `deletedAt: text('deleted_at')` in Drizzle ORM

**PostgreSQL:**

- Use `TIMESTAMPTZ` for `deleted_at`
- Partial unique indexes fully supported
- FK constraints with `ON DELETE CASCADE` work for hard deletes but not soft
  deletes -- still need application-level cascade logic
- Row-level security policies can automatically filter deleted records

**MongoDB:**

- Add `deletedAt: Date | null` field to documents
- Use `{ deletedAt: null }` or `{ deletedAt: { $exists: false } }` in queries
- Create a partial index:
  `{ deletedAt: 1 }, { partialFilterExpression: { deletedAt: null } }`
- Mongoose has plugins (`mongoose-delete`) that add soft delete automatically

**Firestore:**

- Add `deletedAt` field (Firestore Timestamp or null)
- Security rules can filter: `request.resource.data.deletedAt == null`
- Collection group queries can find all deleted items across subcollections

### Frontend Frameworks

**React:** Filter deleted records in service hooks or data layer. Use optimistic
updates for instant feedback on delete/restore. Toast notifications with
`setTimeout` for undo window.

**Vue:** Filter in Pinia stores or composables. Use reactive queries to
automatically exclude deleted records. Teleport-based toast for undo.

**React Native / Mobile:** Service layer filters at the query level. Swipe
actions for delete. Toast/snackbar for undo. Dedicated "Trash" tab or settings
sub-screen.

### ORM Adapters

**Drizzle ORM:**

```
-- Schema
deletedAt: text('deleted_at'),

-- Queries
import { isNull } from 'drizzle-orm';
.where(isNull(table.deletedAt))

-- Soft delete
.set({ deletedAt: nowISO() })
```

**Prisma:**

```
-- Use middleware to auto-filter deleted records
-- Or use @prisma/client/extensions for soft delete
```

**TypeORM:**

```
-- Use @DeleteDateColumn() decorator
-- Enables automatic soft delete with .softRemove() and .recover()
```

---

## Gotchas & Important Notes

- **The #1 bug: forgetting to filter `deletedAt` in a query.** Every new query
  on a soft-deletable table must include the filter. This is not a one-time
  setup -- it's an ongoing discipline. Grep your codebase periodically for
  queries that lack the filter. Consider a linting rule or code review checklist
  item.

- **Join tables don't need soft delete, but queries through them do.** If you
  join `documents` through `document_groups` to reach `groups`, you must check
  `deletedAt` on BOTH `documents` AND `groups`. A document in a soft-deleted
  group should be treated as inaccessible even if the document itself is not
  deleted.

- **Don't update `updatedAt` on soft delete.** The `updatedAt` field should
  reflect the last content edit. The deletion timestamp is `deletedAt`. Mixing
  these up breaks sorting in both the active list and the trash view.

- **Use the same timestamp across a cascade.** When deleting a project and all
  its contents, every record in the cascade should get the same `deletedAt`
  value. This enables batch restore ("restore everything deleted with the
  project") and audit ("what was deleted in this operation?").

- **Soft-deleted parents make children inaccessible.** Even if a document is not
  soft-deleted, if its parent group IS soft-deleted, the document should not
  appear in normal queries. Filter on the parent's `deletedAt` in joins, or
  cascade-delete children explicitly.

- **Unique constraints need special handling.** A soft-deleted record still
  occupies its unique slot. Use partial indexes to exclude deleted records from
  uniqueness checks, or include `deletedAt` in the constraint.

- **Export should exclude soft-deleted records.** When exporting data (JSON,
  CSV, backup), filter out `deleted_at IS NOT NULL` records. Users don't expect
  their trash to appear in exports.

- **Search must filter soft deletes.** Full-text search, fuzzy search, and any
  query-based features must respect the `deletedAt` filter. Deleted documents
  should not appear in search results.

- **Cascading soft deletes need transactions.** If part of a cascade fails, you
  end up with a partially-deleted hierarchy. Always wrap cascading operations in
  a database transaction.

- **Hard delete must respect dependency order.** When permanently purging
  records, delete children before parents (versions before documents, document
  links before groups). Violating this order causes FK constraint failures (in
  databases that have FK constraints) or orphaned records (in databases
  without).

- **Test the negative case.** Don't just test "soft delete removes from list."
  Also test: "soft-deleted record does not appear in search," "soft-deleted
  parent hides child documents," "creating a new record with the same name as a
  soft-deleted one works," and "restore brings the record back exactly as it
  was."
