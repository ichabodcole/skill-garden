# Document Auto-Save with Dual-Layer Debounce Recipe

## Purpose

Implement a document auto-save system that uses two debounce layers to solve two
different problems simultaneously: grouping rapid keystrokes into meaningful
undo/redo commands (user experience) and batching database writes for
performance (system efficiency). A single debounce layer forces a compromise
between these goals; two layers let you optimize each independently.

This recipe is technology-agnostic at the architecture level. The concepts, data
flow, and service API work with any editor component, any database (SQL, NoSQL,
local SQLite, cloud Postgres), and any frontend framework (React, Vue, SwiftUI,
etc.).

## When to Use

- Any app with a text/document editor that needs transparent auto-saving
- When you already have or plan to implement undo/redo and need it to feel
  natural (word-level, not character-level undo)
- Apps where database write performance matters (local SQLite, network calls, or
  battery-sensitive mobile apps)
- Editors that integrate with a versioning system (auto-save modifies the active
  version in-place, not creating new versions)
- Multi-platform apps (desktop + mobile) that need consistent auto-save behavior
  with platform-specific flush triggers

## Architecture Overview

### Core Concept: Two Debounce Layers

Every keystroke passes through two independent debounce gates before reaching
the database. Each gate serves a different purpose and can be tuned
independently.

```
User types characters
        |
        v
+---------------------------------------+
|  Layer 1: Undo Batching               |
|  (e.g., 300ms debounce)               |
|                                        |
|  Groups rapid keystrokes into a single |
|  undo command. Resets timer on each    |
|  new keystroke.                        |
|                                        |
|  Output: "undo commit" (batch of      |
|  changes pushed to undo stack)         |
+------------------+--------------------+
                   |
                   | content-change event
                   v
+---------------------------------------+
|  Layer 2: Database Persistence        |
|  (e.g., 300ms debounce)               |
|                                        |
|  Coalesces undo commits before writing |
|  to database. Resets timer on each     |
|  new undo commit.                      |
|                                        |
|  Output: database write               |
+------------------+--------------------+
                   |
                   v
         +------------------+
         |    Database      |
         |  (SQLite, etc.)  |
         +------------------+
```

### Why Two Layers?

**Layer 1 (Undo Batching):** Without this, pressing undo would remove a single
character. Users expect undo to remove words or phrases. Layer 1 groups
keystrokes during a typing burst (defined by the debounce window) into a single
undo command.

**Layer 2 (Database Persistence):** Without this, every undo commit would
trigger a database write. Layer 2 coalesces multiple undo commits that happen in
quick succession before hitting the database.

**Result with 300ms on each layer:** During sustained typing, undo commits fire
every ~300ms (whenever the user pauses), but database writes only happen ~300ms
after the last undo commit. Effective write interval during typing: ~600ms. When
the user pauses, both layers flush within ~600ms total.

**Why not a single longer debounce?** A single 600ms debounce would give you the
same write frequency, but undo would group 600ms of typing into one step. That
is too coarse - users lose fine-grained undo. Two 300ms layers give you 300ms
undo granularity with 600ms write frequency. You can tune each independently.

### What This Architecture Avoids

- **Not character-level undo.** Would make undo unusable (10 presses to undo a
  short word).
- **Not save-on-every-keystroke.** Would thrash the database, drain battery on
  mobile, and create unnecessary I/O.
- **Not periodic interval saves** (e.g., every 5 seconds). Would risk losing up
  to 5 seconds of work and make undo/redo timing unpredictable.
- **Not creating versions on auto-save.** Auto-save modifies the active version
  in-place. New versions are only created by explicit user action or
  programmatic triggers (like AI operations).

### Trade-offs

- Two debounce layers add complexity vs. one. Debugging requires knowing which
  layer you are looking at.
- Both layers add latency between keystroke and database write (~600ms total in
  default config). For single-user apps with local databases, this is
  acceptable.
- If the app crashes between Layer 1 fire and Layer 2 fire, the undo commit is
  in memory but not yet in the database. This window is brief (~300ms).

---

## Data Flow

### Complete Auto-Save Flow

From keystroke to database, step by step:

```
1. User types a character
2. Editor input handler detects content change
3. Editor calls UndoManager.addChange(diff, beforeState)
4. Editor calls UndoManager.scheduleCommit(afterState, DEBOUNCE_MS)
5. --- Layer 1 debounce: timer resets on each keystroke ---
6. DEBOUNCE_MS elapses with no new input
7. UndoManager.commitBatch() fires:
   - Pushes changes to undo stack
   - Emits "content-change" event with new content
8. Content-change handler receives event
9. Handler marks document as dirty
10. Handler calls debouncedSave(content)
11. --- Layer 2 debounce: timer resets on each undo commit ---
12. DEBOUNCE_MS elapses with no new undo commits
13. debouncedSave fires:
    - Calls updateVersion(activeVersionId, content)
    - Marks document as clean on success
14. Database transaction:
    - Updates version record content
    - Updates document content mirror
```

### Timeline Example (Continuous Typing)

With 300ms debounce on both layers:

```
  0ms: Type "H"
 50ms: Type "e"   -> Layer 1 timer resets to 350ms
100ms: Type "l"   -> Layer 1 timer resets to 400ms
150ms: Type "l"   -> Layer 1 timer resets to 450ms
200ms: Type "o"   -> Layer 1 timer resets to 500ms
500ms: Layer 1 fires -> undo commit "Hello", content-change event
       Layer 2 timer starts (fires at 800ms)
600ms: Type " "   -> Layer 1 timer resets to 900ms
700ms: Type "w"   -> Layer 1 timer resets to 1000ms
800ms: Layer 2 fires -> DB write "Hello" (the last content-change)
       Note: "w" is not yet in the DB (Layer 1 hasn't committed it)
...
```

**Key insight:** The user is always editing the in-memory content. The database
is always slightly behind. The dirty state flag tells the UI whether unsaved
changes exist.

---

## Core Components

### 1. Undo Manager (Layer 1)

The undo manager handles change batching and undo/redo stacks. One instance per
document, created lazily on first edit.

**API surface:**

```
UndoManager
  addChange(change, beforeState)      // Buffer a text change
  scheduleCommit(afterState, delayMs) // Start/restart debounce timer
  commitBatch(afterState)             // Flush immediately
  cancelScheduledCommit()             // Cancel pending timer
  hasPendingBatch() -> boolean        // Check for uncommitted changes
  undo() -> UndoCommand | null        // Pop from undo stack
  redo() -> UndoCommand | null        // Pop from redo stack
  clear()                             // Reset all state
```

**Internal state:**

```
undoStack: UndoCommand[]        // Committed undo commands
redoStack: UndoCommand[]        // Commands available for redo
currentBatch: TextChange[]      // Uncommitted changes in progress
batchTimer: Timer | null        // Layer 1 debounce timer
maxStackSize: number            // FIFO limit on stacks (e.g., 100)
```

**Debounce implementation (pseudocode):**

```
function scheduleCommit(afterState, delayMs):
  if currentBatch is empty:
    return  // Nothing to commit

  cancelScheduledCommit()  // Cancel any existing timer
  batchTimer = setTimeout(delayMs):
    commitBatch(afterState)

function commitBatch(afterState):
  if currentBatch is empty:
    return

  command = {
    id: generateId(),
    changes: clone(currentBatch),
    beforeState: savedBeforeState,
    afterState: afterState,
    timestamp: now()
  }

  undoStack.push(command)
  enforceMaxStackSize()   // FIFO: remove oldest if over limit
  resetBatch()            // Clear currentBatch and timer
```

**Per-document isolation:** Each document gets its own UndoManager instance.
Switching documents does not carry undo history across. Instances are stored in
a Map keyed by document ID and created lazily on first access.

### 2. Editor Component (Layer 1 Trigger)

The editor component captures user input and drives Layer 1.

**Responsibilities:**

- Detect content changes on each input event
- Calculate text diffs between old and new content
- Call `UndoManager.addChange()` and `scheduleCommit()` on each change
- Handle undo/redo keyboard shortcuts (Cmd/Ctrl+Z, Cmd/Ctrl+Shift+Z)
- Flush pending batch on component unmount or document switch

**Immediate commit pattern:** Some discrete operations (like moving a line
up/down) should bypass debouncing and commit immediately. These are intentional,
atomic actions that users expect as individual undo steps:

```
function handleInput(isLineMovement):
  change = calculateDiff(previousContent, currentContent)
  if change:
    undoManager.addChange(change, beforeState)
    if isLineMovement:
      undoManager.commitBatch(afterState)  // Immediate
    else:
      undoManager.scheduleCommit(afterState, DEBOUNCE_MS)  // Debounced
```

### 3. Save Handler (Layer 2)

A debounced function that writes content to the database. Created separately
from the undo manager.

**Pseudocode:**

```
// Create debounced save function
debouncedSave = debounce(async (content):
  if no current document: return
  await versionService.updateVersion(activeVersionId, content)
  markDocumentClean(documentId)
, DEBOUNCE_MS)

// Content change handler (called when Layer 1 emits content-change)
function handleContentChange(newContent):
  if newContent == savedContent:
    markDocumentClean(documentId)
  else:
    markDocumentDirty(documentId)
  debouncedSave(newContent)
```

**Dynamic interval updates:** If the auto-save interval is user-configurable,
recreate the debounced save handler when the setting changes:

```
watch(autoSaveInterval, (newDelay):
  debouncedSave = debounce(saveFunction, newDelay)
)
```

Note: Existing pending saves use the OLD interval until they fire. New changes
use the NEW interval immediately. There is a brief period where both intervals
are "active."

### 4. Dirty State Tracker

Tracks which documents have unsaved changes. Simple Set-based implementation.

**Pattern:**

- **Mark dirty:** Immediately when content changes (optimistic)
- **Mark clean:** Only after database write succeeds (pessimistic)
- **Query:** Check if a document ID is in the dirty set

```
dirtyDocuments: Set<string>

function markDocumentDirty(id):
  dirtyDocuments.add(id)

function markDocumentClean(id):
  dirtyDocuments.delete(id)

function isDocumentDirty(id) -> boolean:
  return dirtyDocuments.has(id)
```

**Why asymmetric timing?** Marking dirty immediately and clean only on success
prevents the UI from showing "saved" while a write is still pending or could
fail. This is the safe default.

### 5. Version Update Service (Database Layer)

The database operation called by Layer 2. This updates the active version
in-place and maintains the content mirror.

**Logic:**

```
function updateVersion(versionId, content):
  Transaction:
    1. Update document_versions.content WHERE id = versionId
    2. Find the document that owns this version
    3. If this version IS the active version:
       Update documents.content = content  (maintain mirror)
    4. Update documents.updatedAt = now()
```

**Critical invariant:** `documents.content` MUST always equal the active
version's content. Every code path that changes content must maintain this
mirror. See the Document Versioning recipe for full details on this pattern.

---

## Flush-on-Exit Pattern

### Why Flush Is Critical

Both debounce layers introduce a window where changes exist in memory but not in
the database. If the app closes during this window, changes are lost. The
flush-on-exit pattern ensures pending saves complete before the app shuts down.

### Flush Points

Every transition out of the editing context must flush both layers:

| Trigger                | What to Flush        | Platform |
| ---------------------- | -------------------- | -------- |
| Document switch        | Layer 1 (undo batch) | All      |
| Editor unmount         | Layer 1 + Layer 2    | All      |
| App close / quit       | Layer 1 + Layer 2    | Desktop  |
| App goes to background | Layer 2              | Mobile   |
| Before undo/redo       | Layer 1 only         | All      |
| Before AI operation    | Layer 1 + Layer 2    | All      |

### Desktop: Window Close / Before-Quit

```
// In the main process or app lifecycle handler:
onBeforeQuit:
  // Signal renderer to flush pending saves
  // Wait for flush confirmation before allowing quit
  // Use IPC to coordinate between processes if needed

onWindowClose:
  // Same pattern - flush before allowing close
```

### Mobile: App Backgrounding

```
// Listen for app state changes
onAppStateChange(nextState):
  if nextState == "background" or nextState == "inactive":
    debouncedSave.flush()  // Force immediate execution of pending save
```

This is especially important on mobile where the OS may terminate backgrounded
apps without warning.

### Document Switching

```
// When switching from Document A to Document B:
onDocumentSwitch(oldDocId, newDocId):
  // 1. Flush Layer 1 for old document
  oldUndoManager = getUndoManager(oldDocId)
  if oldUndoManager and oldUndoManager.hasPendingBatch():
    oldUndoManager.commitBatch(currentEditorState)

  // 2. Layer 2 flush happens automatically because commitBatch
  //    triggers content-change, which triggers debouncedSave

  // 3. Reset editor state for new document
  resetPreviousContent(newDocContent)
```

### Before Undo/Redo

```
function handleUndo():
  // Must flush pending batch first, otherwise undo would operate
  // on an incomplete batch
  if undoManager.hasPendingBatch():
    undoManager.commitBatch(currentState)
  else:
    undoManager.cancelScheduledCommit()

  command = undoManager.undo()
  if command:
    applyInverseChanges(content, command.changes)
```

---

## Coordination with Versioning

Auto-save and document versioning are separate systems that must coordinate
carefully.

### Key Rule: Auto-Save Does NOT Create Versions

Auto-save calls `updateVersion(activeVersionId, content)`, which modifies the
active version's content in-place. It does NOT call `createVersion()`. Creating
a version on every keystroke (or every debounce fire) would produce thousands of
versions and make version history useless.

| Operation                      | Creates Version? | Modifies Active Version? |
| ------------------------------ | ---------------- | ------------------------ |
| Auto-save (typing)             | No               | Yes (in-place update)    |
| Manual "Save Version"          | Yes              | Yes (new becomes active) |
| AI operation (auto-version on) | Yes              | Yes (new becomes active) |

### Content Mirror Maintenance

The `documents.content` field mirrors the active version's content for query
performance (list documents without joining versions). Auto-save must update
both `document_versions.content` AND `documents.content` atomically.

See the Document Versioning recipe for full details on the content mirror
pattern.

### Version Switching Clears Undo

When a user switches to a different version, the undo stack must be cleared. The
undo history belongs to the editing session of the previous version. Carrying it
across versions would cause confusing behavior.

```
function switchVersion(documentId, versionId):
  // ... switch active version in database ...
  clearUndoHistory(documentId)
  markDocumentClean(documentId)
```

---

## Edge Cases

### Rapid Document Switching

Switching documents while a save is pending can cause stale content writes. The
flush-on-switch pattern mitigates this, but there is a subtle window:

```
1. User edits Document A
2. Layer 1 fires -> content-change for Doc A
3. User immediately switches to Document B (before Layer 2 fires)
4. Layer 2 fires with Doc A's content

Is the save applied to the correct document?
```

**Solution:** The debounced save function must capture the document ID at the
time of the content change, not at the time of execution. Alternatively, flush
Layer 2 synchronously on document switch.

### Undo/Redo During Pending Save

If undo fires between Layer 1 and Layer 2, the undo modifies in-memory content
but the pending Layer 2 save still has the pre-undo content. This is handled
because undo triggers a new content-change event, which resets Layer 2's timer
with the post-undo content.

### Settings Change During Pending Save

If the user changes the auto-save interval while a save is pending, the old
timer continues with the old interval. The new interval applies to the next
content change. This brief inconsistency is harmless.

### Empty Content

The system should handle saving empty content. An empty document is still a
valid document. Do not skip saves when content is empty string.

### Large Documents

For documents over ~100KB, the diff calculation in Layer 1 may take measurable
time (>1ms). If this becomes a problem:

- Move diff calculation to a background thread / web worker
- Use a more efficient diff algorithm
- Increase the Layer 1 debounce interval

---

## Settings / Configuration

| Setting            | Type   | Default | Range      | Purpose                        |
| ------------------ | ------ | ------- | ---------- | ------------------------------ |
| `autoSaveInterval` | number | 300ms   | 100-5000ms | Debounce delay for both layers |
| `undoStackLimit`   | number | 100     | 10-500     | Max undo commands per document |

**Why both layers share one interval:** Simplifies the settings UI. Advanced
users could benefit from separate tuning (e.g., 200ms undo batch, 500ms DB
write), but the complexity is rarely worth it. One setting that controls both is
the pragmatic default.

**Platform defaults may differ:** Mobile apps may use a slightly longer default
(e.g., 500ms) to reduce battery impact from frequent writes, while desktop apps
use 300ms for a snappier feel.

---

## Implementation Phases

### Phase 1: Undo Manager (Layer 1)

1. Implement the UndoManager class with batch buffering and debounced commits
2. Implement text diff utilities (calculate change, apply forward, apply
   inverse)
3. Define types: `TextChange`, `UndoCommand`, `EditorState`
4. Add per-document undo manager instances (Map keyed by document ID)
5. Integrate with editor: capture before-state, calculate diff, schedule commit

**Validate:** Type rapidly, press undo - should remove a word/phrase, not single
characters. Press redo - should restore. Switch documents - undo history should
be isolated per document.

### Phase 2: Debounced Save (Layer 2)

1. Create a debounced save function using your framework's debounce utility
2. Wire content-change events from Layer 1 to the debounced save
3. Implement the version update service (update active version in-place)
4. Maintain content mirror (`documents.content` stays in sync)

**Validate:** Type rapidly, check database - should see writes every ~600ms (sum
of both debounce intervals), not on every keystroke. Content in database should
match editor content after debounce settles.

### Phase 3: Dirty State Tracking

1. Implement dirty state Set (mark dirty on change, clean on save success)
2. Wire UI indicator (dot, icon, or text showing unsaved state)
3. Handle edge case: content reverted to saved state should mark clean

**Validate:** Edit a document - dirty indicator appears. Wait for auto-save -
indicator clears. Edit and immediately undo back to saved content - indicator
should clear.

### Phase 4: Flush-on-Exit

1. Add flush on document switch (commit pending undo batch)
2. Add flush on editor unmount / component destroy
3. Add platform-specific flush:
   - Desktop: before-quit handler, window close handler
   - Mobile: AppState background listener
4. Add flush before undo/redo operations

**Validate:** Edit a document, immediately switch to another - no data loss.
Edit a document, close the app - changes are saved. Edit a document, background
the app (mobile) - changes are saved.

### Phase 5: Settings Integration (Optional)

1. Add configurable auto-save interval to settings
2. Recreate debounced save handler when setting changes
3. Add configurable undo stack limit
4. Validate interval bounds (min/max)

**Validate:** Change auto-save interval in settings - new interval takes effect
on next edit. Set interval to maximum - undo batches are larger, DB writes less
frequent.

---

## Adapting to Different Tech Stacks

### Editor Frameworks

**Plain textarea / ContentEditable:** Listen to `input` and `beforeinput`
events. Use `beforeinput` to capture cursor state before the DOM mutation.

**CodeMirror / ProseMirror / TipTap:** These editors have built-in change
tracking. You may not need Layer 1 at all if the editor provides good undo
batching. Layer 2 (debounced persistence) is still needed.

**React Native TextInput:** Listen to `onChangeText`. Cursor state is available
via `onSelectionChange`. Note: `beforeinput` equivalent does not exist in React
Native; capture previous content in a ref.

### Debounce Utilities

**lodash/debounce, VueUse useDebounceFn:** Common choices. Ensure the utility
supports `.flush()` for immediate execution (needed for flush-on-exit).

**Custom setTimeout:** Simple and dependency-free. The pseudocode in this recipe
uses this approach. Must implement `.flush()` manually.

**RxJS debounceTime:** Works well in Angular/RxJS codebases. Wire Layer 1 as an
Observable.

### Databases

**SQLite (local-first apps):** Transactions are fast. 300ms debounce is more
than sufficient. The bottleneck is I/O, not query time.

**PostgreSQL / Network databases:** Consider a longer Layer 2 debounce (500ms+)
to account for network latency. Consider optimistic local state with background
sync.

**Local-first with sync (PowerSync, CRDTs):** Auto-save writes to the local
database. The sync layer picks up changes asynchronously. No need to coordinate
auto-save with sync timing - just save locally and let sync catch up.

### Platforms

**Desktop (Electron, Tauri):** Flush on `before-quit` and `window-all-closed`
events. In multi-process architectures (Electron), coordinate flush via IPC
between renderer and main process.

**Mobile (React Native, SwiftUI):** Flush on app backgrounding. On iOS, use
`AppState` listener. On Android, same approach works. Be aware that the OS can
terminate backgrounded apps without notice - flush must be synchronous (use
`.flush()`, not another debounced call).

**Web (SPA):** Flush on `beforeunload` event. Note: async operations in
`beforeunload` are unreliable. Consider using `navigator.sendBeacon()` for
critical saves, or ensure saves complete synchronously.

---

## Gotchas & Important Notes

- **Debug carefully: know which layer you are looking at.** When a save seems
  delayed or content seems stale, check whether the issue is in Layer 1 (undo
  batching) or Layer 2 (DB persistence). They are independent timers.

- **Flush both layers in tests.** Async tests that check database state must
  wait for BOTH debounce layers to fire (~600ms total with default settings).
  Alternatively, mock timers carefully - two layers means nested setTimeout
  calls.

- **Do not flush Layer 2 synchronously on every document switch.** Flush Layer 1
  (commit the undo batch) synchronously, but let Layer 2 fire on its own
  schedule. The content-change event from Layer 1's commit will trigger Layer 2.
  Forcing both synchronously on every switch adds unnecessary latency.

- **The dirty flag is NOT the same as "has pending debounce."** A document is
  dirty from the moment content changes until the database write succeeds. The
  debounce timers are internal implementation details. The dirty flag is the
  user-facing indicator.

- **Auto-save does NOT create versions.** This is the most common
  misunderstanding when integrating with versioning. Auto-save calls
  updateVersion (in-place), never createVersion. See the Document Versioning
  recipe.

- **Undo history is ephemeral.** It lives in memory only and is lost on app
  restart. This is intentional - persisting undo history adds significant
  complexity (serialization, storage, versioning the undo format itself) for
  marginal value. The version history system provides cross-session recovery.

- **Shared undo manager across platforms.** If your app runs on multiple
  platforms (desktop + mobile), share the UndoManager class in a common package.
  Only the editor integration (input handling, keyboard shortcuts) and the flush
  triggers differ per platform.

- **Mobile battery impact.** On mobile, every database write has a battery cost.
  Consider defaulting to a longer debounce interval (e.g., 500ms) on mobile than
  desktop (300ms). The difference is imperceptible to users but meaningful for
  battery life during extended editing sessions.

- **Document ID capture in debounced save.** The debounced save closure must
  reference the document ID from when the content changed, not when the debounce
  fires. Otherwise, rapid document switching can cause saves to target the wrong
  document.
