# Document Versioning Recipe

## Purpose

Implement a linear document versioning system that lets users save milestones,
browse history, and restore previous states. This is the "save game" pattern for
documents - not real-time collaborative editing or git-style branching, but a
simple, reliable system for preserving document states over time.

The recipe is technology-agnostic at the architecture level. The concepts, data
model, and service API work with any database (SQL, NoSQL, local SQLite, cloud
Postgres) and any frontend framework (React, Vue, SwiftUI, etc.).

## When to Use

- Any app with user-editable documents, notes, or text content
- Content that gets transformed by AI operations (preserving "before" state)
- Apps where users want named save points ("Draft", "Final", "Before AI edit")
- When you need undo-beyond-session (undo history survives app restart)

## Architecture Overview

### Core Concept: Active Version Model

Every document has exactly one **active version** that represents the current
working state. The active version is mutable (updated by auto-save). All other
versions are frozen snapshots.

```
Document: "Meeting Notes"
├── Version 4 (active) - "Final Edit"     ← Mutable, shown in editor
├── Version 3 - "AI Enhanced"             ← Frozen snapshot
├── Version 2 - "AI Organized"            ← Frozen snapshot
└── Version 1 - "Original"                ← Frozen snapshot (auto-created)
```

**Key properties:**

- **Linear, not branching.** Versions form a simple numbered sequence (1, 2,
  3...). No tree structure, no merge conflicts, no DAG.
- **Active version is mutable.** Auto-save updates the active version in-place.
  No new version is created on every keystroke.
- **Manual milestones.** New versions are only created by explicit user action
  or programmatic triggers (like AI operations). This prevents version bloat.
- **Configurable limits.** A maximum version count per document (default: 20)
  prevents unbounded storage growth. Users must manually delete old versions.

### Why This Design?

**Problem it solves:** "I ran an AI operation on my notes and want the original
back" or "I want to save the current state before making big changes."

**What it avoids:**

- **Not CRDT/OT.** No real-time collaboration complexity.
- **Not git-style.** No branches, merges, or diffs. Each version stores full
  content.
- **Not auto-versioning-on-every-change.** Would create thousands of versions.
  Auto-save modifies the active version in-place.

**Trade-offs:**

- Full content per version (not diffs) = simple implementation, higher storage
- No auto-pruning = users manage their own version count
- Linear history = can't model "what if I tried a different approach"

---

## Data Model

### Tables

Two tables with a bidirectional relationship:

```
┌────────────────────────┐         ┌──────────────────────────┐
│      documents         │────┐    │    document_versions     │
│                        │    │    │                          │
│ id (PK)                │    │    │ id (PK)                  │
│ title                  │    └───→│ documentId (FK)          │
│ content (mirror)       │         │ content                  │
│ activeVersionId ───────┼────────→│ versionNumber            │
│ updatedAt              │         │ label                    │
│ ...                    │         │ createdAt                │
└────────────────────────┘         │ createdBy                │
                                   └──────────────────────────┘
```

### `document_versions` Schema

| Column          | Type      | Constraints                 | Purpose                                             |
| --------------- | --------- | --------------------------- | --------------------------------------------------- |
| `id`            | text/uuid | PK                          | Unique version identifier                           |
| `documentId`    | text/uuid | NOT NULL, FK → documents.id | Parent document                                     |
| `content`       | text      | NOT NULL                    | Full document content snapshot                      |
| `label`         | text      | nullable                    | Human-readable name ("Original", "Before AI edit")  |
| `versionNumber` | integer   | NOT NULL                    | Sequential per document (1, 2, 3...)                |
| `createdAt`     | timestamp | NOT NULL                    | When version was created                            |
| `createdBy`     | text      | NOT NULL                    | Origin: `'user'`, `'ai:organize'`, `'ai:agent:xyz'` |

**Required indexes:**

- `(documentId)` - Fast version listing
- `(documentId, versionNumber)` UNIQUE - Enforces sequential numbering, prevents
  duplicates
- `(createdAt)` - Chronological queries

**On the `documents` table, add:**

- `activeVersionId` (text, nullable) - Points to the current active version
- `content` (text) - Mirrors the active version's content (see "Content
  Mirroring" below)

### Content Mirroring

The `documents.content` field duplicates the active version's content. This
redundancy exists for:

1. **Query performance** - List documents without joining versions
2. **Backward compatibility** - Existing code that reads `document.content`
   keeps working
3. **Migration safety** - Can add versioning to existing documents incrementally

**Invariant:** `documents.content` MUST always equal the active version's
content. Every operation that changes content or switches versions must maintain
this.

**Future optimization:** Could remove `documents.content` and always join, but
the duplication is cheap and simplifies reads.

### Optional Fields

Depending on your needs, you may also want:

| Column      | Type           | Purpose                                                                       |
| ----------- | -------------- | ----------------------------------------------------------------------------- |
| `sessionId` | text, nullable | Groups edits within an agent/automation session (see "Session Deduplication") |
| `ownerId`   | text, nullable | Denormalized owner for row-level security / sync rules                        |
| `metadata`  | json, nullable | Extensible metadata (word count, AI model used, etc.)                         |

---

## Service Layer

The version service is the core of the system. It should be a standalone module
with no UI dependencies - just database operations and business rules.

### Service API

```
VersionService
├── createVersion(params)        → DocumentVersion
├── getVersions(documentId)      → DocumentVersion[]
├── getActiveVersion(documentId) → DocumentVersion | null
├── switchVersion(documentId, versionId)   → void
├── updateVersion(versionId, content)      → void
├── deleteVersion(documentId, versionId)   → void
├── renameVersion(versionId, label)        → void
└── duplicateVersion(versionId)            → DocumentVersion
```

### Operation Details

#### `createVersion(params)`

The most complex operation. Handles limit enforcement and version numbering.

**Parameters:**

```
{
  documentId: string       // Parent document
  content: string          // Content to snapshot
  label?: string           // Optional label (default: auto-generated)
  createdBy: string        // 'user' | 'ai:*'
  setActive?: boolean      // Make this the active version (default: true)
}
```

**Logic:**

1. Verify document exists (throw if not found)
2. Count existing versions for this document
3. Compare count against configured limit
4. If limit reached, throw `VersionLimitError` (do NOT silently skip)
5. Calculate `versionNumber = currentMaxVersionNumber + 1`
6. Generate UUID for version ID
7. Insert version record
8. If `setActive: true`:
   - Update `documents.activeVersionId` to new version ID
   - Update `documents.content` to new version content
9. Return created version

**Important:** Steps 7-8 should run in a transaction.

#### `updateVersion(versionId, content)`

Called during auto-save. Updates an existing version's content in-place.

**Logic:**

1. Update `document_versions.content` where `id = versionId`
2. Look up whether this version is the active version for its document
3. If it IS the active version, also update `documents.content` (maintain
   mirror)

**Important:** This does NOT create a new version. Auto-save modifies the active
version in-place. This is a deliberate design choice to avoid version bloat from
continuous typing.

#### `switchVersion(documentId, versionId)`

Changes which version is displayed in the editor.

**Logic:**

1. Verify the version exists and belongs to this document
2. Fetch the version's content
3. Update `documents.activeVersionId = versionId`
4. Update `documents.content = version.content` (maintain mirror)
5. Update `documents.updatedAt`

**UI consideration:** Switching versions should clear the editor's undo/redo
stack, since the undo history belongs to the previous version's editing session.

#### `deleteVersion(documentId, versionId)`

Removes a version permanently.

**Logic:**

1. Look up the document's `activeVersionId`
2. If `versionId === activeVersionId`, throw `ActiveVersionOperationError` (user
   must switch to a different version first)
3. Delete the version record

**Important:** Version numbers are NOT renumbered after deletion. If you delete
Version 2 from [1, 2, 3], you get [1, 3]. This is intentional - version numbers
are stable identifiers, not array indices.

#### `duplicateVersion(versionId)`

Creates a copy of an existing version as a new version.

**Logic:**

1. Fetch the original version
2. Create a new version with the same content
3. Label: `"{original label} (copy)"` or `"Version copy"`
4. New version number = max + 1
5. Do NOT set as active (user can switch manually)

### Document Creation Integration

When a new document is created, Version 1 must be created atomically:

```
Transaction:
  1. Insert document (activeVersionId = null initially)
  2. Insert Version 1 (label = "Original", versionNumber = 1, createdBy = "user")
  3. Update document.activeVersionId = Version 1 ID
```

This ensures no document exists without at least one version.

### Error Types

Define two domain-specific errors:

**`VersionLimitError`** - Thrown when version count reaches the configured
limit.

```
Properties:
  - documentId: string
  - currentCount: number
  - maxCount: number
```

The UI should catch this and show a warning like "Maximum versions reached
(20/20). Delete old versions to save new ones."

**`ActiveVersionOperationError`** - Thrown when attempting to delete the active
version. The UI should explain that the user must switch to a different version
before deleting.

---

## Auto-Save Integration

Auto-save and versioning interact but are separate concerns:

| Operation                       | Creates New Version? | Modifies Active Version?         |
| ------------------------------- | -------------------- | -------------------------------- |
| Auto-save (typing)              | No                   | Yes (in-place update)            |
| Manual "Save Version"           | Yes                  | Yes (new version becomes active) |
| AI operation (auto-version ON)  | Yes                  | Yes (new version becomes active) |
| AI operation (auto-version OFF) | No                   | Yes (in-place update)            |

**Pattern:** Auto-save calls `updateVersion(activeVersionId, content)`. "Save
Version" calls `createVersion(...)`. These are fundamentally different
operations.

**Debouncing:** Auto-save should be debounced (e.g., 300ms) to batch rapid
keystrokes into single writes.

---

## AI / Automation Integration

When AI operations modify document content, versioning can optionally preserve
the "before" state.

### Auto-Versioning Pattern

```
User triggers AI operation (e.g., "Organize")
         ↓
Check auto-versioning setting
         ↓
If enabled AND content changed:
  ├─ Create new version with AI output
  │  (label: "AI Organized", createdBy: "ai:organize")
  ├─ New version becomes active
  └─ Previous version preserved as frozen snapshot
         ↓
If disabled:
  └─ Update active version in-place (no snapshot preserved)
```

### Session Deduplication (Advanced)

If your app supports AI agents or automations that make many small edits, you
need session deduplication to prevent consuming all version slots.

**Problem:** An AI agent makes 50 small edits. Without deduplication, each edit
creates a new version, hitting the limit immediately.

**Solution:** Assign a `sessionId` to a group of related edits. If a version
with that `sessionId` already exists for the document, update it in-place
instead of creating a new version.

Add a UNIQUE constraint: `(documentId, sessionId)` to enforce one version per
session per document.

**Logic in `createVersion`:**

```
If sessionId is provided:
  Look for existing version with this (documentId, sessionId)
  If found:
    Update existing version's content in-place
    Return existing version (no new version created)
  If not found:
    Create new version normally (with sessionId stored)
```

This collapses an entire AI session into a single version slot.

### Creator Tracking Convention

The `createdBy` field uses a namespace pattern:

- `"user"` - Human-initiated save
- `"ai:organize"` - AI organize workflow
- `"ai:enhance"` - AI enhance workflow
- `"ai:agent:<agentId>"` - Specific AI agent
- `"ai:pipeline:<executionId>"` - Automation pipeline

This lets the UI distinguish human vs AI versions and show appropriate labels.

---

## Version Limits

### Enforcement

- **Default limit:** 20 versions per document
- **Configurable range:** 5-100 (or whatever makes sense for your app)
- **Enforcement point:** `createVersion()` checks count BEFORE inserting
- **No auto-pruning.** Users must manually delete old versions. This prevents
  surprise data loss.

### UI Indicators

Show version count and limit status in the UI:

- **Normal:** "4 versions" (no limit shown if well under limit)
- **Approaching limit** (within ~20% or 3 versions): Warning indicator, "18 / 20
  versions"
- **At limit:** Disable "Save Version" button, show message: "Maximum versions
  reached. Delete old versions to save new ones."

---

## Settings

If your app has user-configurable settings, expose these:

| Setting                             | Type    | Default    | Purpose                             |
| ----------------------------------- | ------- | ---------- | ----------------------------------- |
| `versioning.enabled`                | boolean | true       | Master toggle for versioning UI     |
| `versioning.maxVersionsPerDocument` | number  | 20         | Version limit (5-100)               |
| `versioning.defaultLabelStrategy`   | enum    | "numbered" | How auto-generated labels work      |
| `versioning.autoVersionOnAI`        | boolean | false      | Create version before AI operations |

**Label strategies:**

- `"numbered"` - "Version 1", "Version 2", ...
- `"timestamped"` - "Jan 15, 3:30 PM"
- `"custom"` - Always prompt user for label name

---

## UI Components

The versioning UI consists of these components (adapt to your framework):

### 1. Version Dropdown / Selector

Shows in the document header/toolbar. Displays the current version and lets
users browse history.

**Features:**

- List all versions (newest first, active version highlighted)
- Click to switch active version
- Show version label, creator (user/AI badge), timestamp
- Show version count and limit warnings
- Lazy-load versions on open (don't load until user clicks)

### 2. Save Version Button

Simple button in the toolbar. Opens a dialog to optionally name the version.

**States:**

- Normal: clickable
- Disabled: no document selected, or version limit reached
- Loading: version being saved

### 3. Save Version Dialog

Modal with a text input for the version label.

**Features:**

- Pre-filled with auto-generated label (based on label strategy setting)
- User can customize or accept default
- Save and Cancel buttons

### 4. Version Management Panel

Full management view for all versions. Can be a sidebar, modal, or dedicated
page.

**Per-version actions:**

- **Set Active** - Switch editor to this version
- **Rename** - Inline edit the label
- **Delete** - With confirmation dialog (disabled for active version)
- **Duplicate** - Create a copy as a new version
- **Content preview** - Truncated preview of version content

**Footer:** Version count, limit indicator, limit warnings

### Display Utilities

Helper functions for formatting version data in the UI:

- `formatVersionLabel(version)` - Returns label or fallback "Version {n}"
- `formatTimestamp(date)` - Locale-aware date/time formatting
- `formatCreatorLabel(createdBy)` - "User" vs "AI generated" vs specific agent
  name
- `previewContent(content, maxLength)` - Truncated content with ellipsis
- `isVersionLimitReached(count, max)` - Boolean check
- `isApproachingLimit(count, max)` - Warning threshold check (within 20% or 3)

---

## Implementation Phases

When implementing this recipe, follow these phases in order:

### Phase 1: Data Model & Service Layer

1. Add `document_versions` table to your schema
2. Add `activeVersionId` to your `documents` table (if not already present)
3. Create indexes
4. Run migration
5. Implement `VersionService` with all operations
6. Implement `VersionLimitError` and `ActiveVersionOperationError`
7. Modify document creation to atomically create Version 1

**Validate:** Create a document, verify Version 1 exists, verify
`activeVersionId` is set.

### Phase 2: Auto-Save Integration

1. Modify your existing document update/save flow to call
   `versionService.updateVersion()` instead of directly writing content
2. Ensure the content mirror (`documents.content`) stays in sync
3. Verify auto-save does NOT create new versions

**Validate:** Edit a document, verify only one version exists (Version 1),
verify content updates in both `documents.content` and the version record.

### Phase 3: Manual Version Save

1. Add "Save Version" button to UI
2. Add save dialog with label input
3. Wire to `versionService.createVersion()`
4. Add toast/notification on success
5. Handle `VersionLimitError` in UI

**Validate:** Create a document, make edits, save a version, verify two versions
exist, verify new version is active.

### Phase 4: Version Browsing & Switching

1. Add version dropdown/selector to UI
2. Wire to `versionService.getVersions()` and `switchVersion()`
3. Implement lazy loading (load versions on dropdown open)
4. Implement version cache in your state management
5. Clear editor undo stack on version switch

**Validate:** Switch between versions, verify editor content changes, verify
switching back restores previous content.

### Phase 5: Version Management

1. Add version management panel/dialog
2. Implement rename, delete, duplicate operations
3. Add active version deletion guard in UI
4. Add content preview
5. Add limit warnings and indicators

**Validate:** Rename a version, delete a non-active version, try to delete
active version (should be blocked), duplicate a version.

### Phase 6: Settings & AI Integration (Optional)

1. Add versioning settings to your settings system
2. Implement configurable version limit
3. Implement label strategy setting
4. Add auto-versioning for AI operations (if applicable)
5. Add session deduplication (if applicable)

---

## Adapting to Different Tech Stacks

### Database Adapters

**SQLite (local-first apps):**

- Use `TEXT` for IDs, `INTEGER` for timestamps (unix ms or ISO string)
- Transactions via your SQLite driver's transaction API
- Indexes work the same as in any SQL database

**PostgreSQL:**

- Use `TEXT` or `UUID` for IDs, `TIMESTAMPTZ` for timestamps
- Use `ON DELETE CASCADE` for the `documentId` FK
- Consider row-level security via an `ownerId` column

**NoSQL (Firestore, MongoDB, etc.):**

- Versions can be a subcollection under documents
- Version numbering requires an atomic counter or transaction
- The content mirror pattern may not be needed if reads are cheap

### Frontend Frameworks

**React:** Version state in a context or Zustand store. Components: dropdown,
dialog, management panel. Custom hooks for version operations.

**Vue:** Pinia store for version state. Composables for version operations,
dialogs, and auto-versioning. Components for dropdown, dialog, panel.

**SwiftUI / Native:** ViewModel with published version state. Native sheet/modal
for dialogs. List view for version management.

### Multi-Platform Apps

If your app runs on multiple platforms (desktop + mobile):

- **Share the service layer logic.** The version service API should be identical
  across platforms. Only the database driver differs.
- **Share the data model.** Use the same schema everywhere.
- **Platform-specific UI.** Each platform builds its own version UI components.
- **Sync considerations.** If versions sync between devices, add an `ownerId`
  column for row-level filtering in sync rules.

---

## Gotchas & Important Notes

- **Version numbers are stable.** Never renumber after deletion. Treat them as
  identifiers, not array positions. Gaps are fine (1, 3, 5 is valid).

- **Auto-save does NOT create versions.** This is the most common
  misunderstanding. Auto-save updates the active version in-place. Only explicit
  "Save Version" or programmatic triggers create new versions.

- **Active version cannot be deleted.** Enforce this at the service layer AND
  the UI layer. The service should throw; the UI should disable the button.

- **Document creation must be atomic.** Always create Version 1 in the same
  transaction as the document. A document without a version is an invalid state.

- **Content mirror must stay in sync.** Every code path that changes content or
  switches versions must update both `document_versions.content` AND
  `documents.content`. Missing one causes data inconsistency.

- **No auto-pruning.** Resist the temptation to auto-delete old versions. Users
  don't expect their saved milestones to disappear. If storage is a concern,
  lower the default limit rather than pruning silently.

- **Full content, not diffs.** Each version stores the complete document. This
  is intentional - diffs add complexity (computing, applying, handling
  corruption) for minimal storage savings on text documents. If your documents
  are very large (100KB+), consider diff storage as a future optimization.

- **Clear undo on version switch.** The editor's in-memory undo stack belongs to
  the editing session of the previously active version. Switching versions must
  clear it to avoid confusing undo behavior.

- **Lazy-load versions.** Don't load the full version list when opening a
  document. Load it when the user opens the version dropdown. Most users work
  with the active version and never look at history.
