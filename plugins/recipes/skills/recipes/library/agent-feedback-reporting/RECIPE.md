# Agent Feedback Reporting Recipe

## UI Reference

See `references/agent-feedback-mockup.html` for an interactive prototype of the
admin feedback list and detail panel UI. Open in a browser to click through
states: default list, selected entry (open/addressed), search, filtered, and
archived views.

## Purpose

This recipe implements a pattern for giving AI agents a structured way to report
difficulties — unclear instructions, missing context, repeated failures, or
anything that degraded the quality of their output. The feedback is captured
during execution, persisted with contextual enrichment, and surfaced in an admin
UI with a lightweight triage workflow.

This recipe is **technology-agnostic at the architecture level**. The pattern
works with any agentic framework (Mastra, LangChain, direct SDK calls, MCP
servers), any database, and any frontend. The concepts and data model are the
transferable artifact; adapt implementation details to your stack.

## When to Use

- You're running AI agents in a production pipeline and want visibility into
  where they struggle
- You want agents to be able to surface issues without modifying their primary
  output
- You need an admin-facing inbox for reviewing, triaging, and acting on agent
  feedback
- You're iterating on agent prompts and want structured signal about what's
  confusing or underspecified
- You have multiple agents and want to correlate feedback across agent IDs,
  model IDs, and task types

## Architecture Overview

The system has four layers:

```
┌─────────────────────────────────────────────────────┐
│  AGENT EXECUTION                                    │
│  Agent calls reportFeedback() tool → pushes to      │
│  module-level registry during execution             │
└───────────────────────┬─────────────────────────────┘
                        │ (in-memory, sync)
┌───────────────────────▼─────────────────────────────┐
│  IN-MEMORY REGISTRY                                 │
│  Module-level array accumulates entries per run.    │
│  Reset before each run. Step context set here too.  │
└───────────────────────┬─────────────────────────────┘
                        │ (after agent.generate() returns)
┌───────────────────────▼─────────────────────────────┐
│  PERSISTENCE LAYER                                  │
│  Step reads registry + enriches with context        │
│  (agentId, stepName, modelId, agentInput).          │
│  Batch inserts to DB.                               │
└───────────────────────┬─────────────────────────────┘
                        │ (HTTP API)
┌───────────────────────▼─────────────────────────────┐
│  ADMIN UI                                           │
│  List + detail panel. Search/filter by agent,       │
│  section type, model. Status triage workflow.       │
└─────────────────────────────────────────────────────┘
```

### Key Design Decisions

**The tool does NOT touch the database.** The feedback tool just pushes to an
in-memory array. Persistence is handled by the orchestrating step _after_ the
agent returns. This keeps the tool stateless and decoupled from DB dependencies,
and allows batch insertion rather than one write per feedback call.

**Context is added at persist time, not by the agent.** The agent only provides
what it naturally knows: what it struggled with, and optionally a category.
Everything else — which agent ran, which step, what model, what the full input
prompt was — is enriched by the calling step. This prevents the agent from
having to understand its own execution context, and ensures enrichment is always
accurate.

**Keep the feedback schema intentionally freeform at first.** Resist the urge to
give the agent a structured schema (predefined categories, severity levels,
etc.). A freeform string reveals natural failure patterns before you know what
structure is useful. You can formalize the schema after observing real feedback.

**Status and archive are independent concepts.** `status` tracks workflow state
(`open` → `addressed`). `archived` tracks visibility (hidden from default inbox
view). An addressed entry can remain visible; an open entry can be archived to
suppress noise. This avoids the ambiguity of a single status field trying to
serve both purposes.

**The registry resets between runs.** This is critical — the registry must be
cleared before each agent run, or entries from previous runs contaminate the
current run's feedback. Reset in the same place you initialize the run (e.g.,
before `agent.generate()`).

## Data Model

### Core Table: `agent_feedback`

```sql
CREATE TABLE agent_feedback (
  id           TEXT PRIMARY KEY,

  -- Correlation anchor: the entity the agent was processing when feedback was
  -- generated (e.g., a story, document, or task). This is NOT "feedback about
  -- this entity" — it's "feedback generated while working on this entity."
  -- Lets you look up what was being processed to understand the context.
  -- Nullable if your use case has no discrete processing entity (see notes below).
  -- Cascade delete so feedback is cleaned up with the parent.
  entity_id    TEXT REFERENCES your_entity(id) ON DELETE CASCADE,

  -- Agent context (set by step at persist time, not by the agent)
  agent_id     TEXT NOT NULL,        -- e.g., 'story-writer', 'code-reviewer'
  step_name    TEXT NOT NULL,        -- e.g., 'write-story-step'
  model_id     TEXT,                 -- resolved model identifier
  agent_input  TEXT,                 -- full input prompt sent to the agent

  -- Agent-provided feedback
  feedback     TEXT NOT NULL,        -- freeform text from the agent
  category     TEXT,                 -- optional metadata (e.g., section type)

  -- Admin workflow
  status       TEXT NOT NULL DEFAULT 'open',  -- 'open' | 'addressed'
  archived     INTEGER NOT NULL DEFAULT 0,    -- 0 | 1 (boolean)
  admin_notes  TEXT,                          -- note when marking as addressed
  addressed_at INTEGER,                       -- timestamp

  created_at   INTEGER NOT NULL
);

CREATE INDEX idx_agent_feedback_entity ON agent_feedback(entity_id);
CREATE INDEX idx_agent_feedback_status ON agent_feedback(status);
```

**Field notes:**

| Field         | Notes                                                                                                  |
| ------------- | ------------------------------------------------------------------------------------------------------ |
| `entity_id`   | Correlation anchor — the entity being processed when feedback was generated. Optional. See note below. |
| `agent_id`    | Allows filtering/grouping by agent type when you have multiple agents.                                 |
| `agent_input` | Store the full prompt for correlation — essential for debugging why the agent struggled.               |
| `category`    | Optional metadata. In a story writer this might be `section_type`; in a code reviewer `file_type`.     |
| `status`      | Workflow state. Keep simple: open or addressed.                                                        |
| `archived`    | Visibility toggle, independent from status. Do NOT conflate with status.                               |
| `admin_notes` | Captures what was done in response — valuable for pattern analysis.                                    |

**`entity_id` — correlation anchor, not subject.** This field is not "feedback
about this entity" — it's "feedback generated while the agent was processing
this entity." It lets you cross-reference the feedback with the output (e.g.,
open the story that was being written when the agent struggled) to understand
the context. **Optional:** if your use case has no discrete processing entity
(e.g., an MCP server responding to ad-hoc tool calls), make this nullable or
omit it. Cascade delete keeps feedback tidy when the parent entity is removed.

## Implementation Process

### Phase 1: In-Memory Registry

Create a module-level registry that accumulates feedback entries during an agent
run. This pattern mirrors any "run-level accumulator" (cost tracking, log
collection, etc.):

```typescript
// feedback-registry.ts

type FeedbackEntry = {
  feedback: string;
  category?: string;
};

let entries: FeedbackEntry[] = [];
let agentInput: string | null = null;
let modelId: string | null = null;

export function pushFeedbackEntry(entry: FeedbackEntry): void {
  entries.push(entry);
}

export function getFeedbackEntries(): FeedbackEntry[] {
  return [...entries]; // return a copy
}

export function resetFeedbackRegistry(): void {
  entries = [];
  agentInput = null;
  modelId = null;
}

export function setAgentInput(input: string): void {
  agentInput = input;
}

export function setModelId(id: string): void {
  modelId = id;
}

export function getAgentInput(): string | null {
  return agentInput;
}

export function getModelId(): string | null {
  return modelId;
}
```

**CRITICAL:** Call `resetFeedbackRegistry()` at the START of each run, before
`agent.generate()`. If you reset after, you'll lose entries on error. If you
forget entirely, entries from run N contaminate run N+1.

**Validate:** Confirm registry starts empty, accumulates entries during a run,
and clears correctly on reset.

### Phase 2: The Feedback Tool

Define a minimal tool that pushes to the registry:

```typescript
// report-feedback.tool.ts

import { pushFeedbackEntry } from "./feedback-registry";

const reportFeedbackTool = createTool({
  id: "reportFeedback",
  description: `Report difficulties, unclear instructions, missing context,
    or anything that prevented you from completing a task well. Call this
    after completing your primary task if you encountered issues. Do not
    let uncertainty about whether to report stop you — if you struggled,
    report it.`,
  inputSchema: z.object({
    feedback: z
      .string()
      .describe(
        "Your observations about what was difficult, unclear, or missing. " +
          "Be specific about what context or information would have helped."
      ),
    category: z
      .string()
      .optional()
      .describe(
        "Optional: a category or label for the feedback (e.g., the task type or section)"
      ),
  }),
  outputSchema: z.object({ acknowledged: z.boolean() }),
  execute: async ({ context: { feedback, category } }) => {
    pushFeedbackEntry({ feedback, category });
    return { acknowledged: true };
  },
});
```

**Tool description guidelines:**

- Tell the agent WHEN to call it (after completing primary task)
- Tell the agent it's optional but encouraged
- Don't provide categories in the description — this biases the agent toward
  predefined labels before you understand natural patterns
- The `acknowledged: true` response closes the loop without adding noise

**Register this tool with your agent** alongside your other tools. Make it
optional in the agent prompt — phrase it as "if you encountered any
difficulties, call reportFeedback before finishing."

**Validate:** Run the agent with a deliberately confusing or incomplete prompt.
Verify the tool is called and entries appear in the registry.

### Phase 3: Step Integration

In the step that runs the agent, capture context and persist after generation:

```typescript
// your-agent-step.ts

import {
  resetFeedbackRegistry,
  setAgentInput,
  setModelId,
  getFeedbackEntries,
  getAgentInput,
  getModelId,
} from "./feedback-registry";
import { insertFeedbackEntries } from "./feedback.repository";

async function runAgentStep(entityId: string, input: string) {
  // 1. Reset registry at run start (MUST be first)
  resetFeedbackRegistry();

  // 2. Capture step context before generate
  setAgentInput(input);
  setModelId(await resolveModelId()); // however you get the model ID

  // 3. Run the agent
  const result = await agent.generate([{ role: "user", content: input }], {
    maxSteps: 25,
    // ... other options
  });

  // 4. After generate returns, persist feedback if any
  const feedbackEntries = getFeedbackEntries();
  if (feedbackEntries.length > 0) {
    await insertFeedbackEntries(entityId, feedbackEntries, {
      agentId: "your-agent-id",
      stepName: "your-step-name",
      modelId: getModelId(),
      agentInput: getAgentInput(),
    });
  }

  return result;
}
```

**Why capture context before `generate()`?** The model ID may be resolved
dynamically (e.g., from a configuration service that picks the latest default).
Capture the resolved value at execution time so feedback records reflect what
actually ran, not what was configured.

**Validate:** Run a full agent execution and check the database. Confirm
`agent_input` and `model_id` are populated correctly alongside the feedback.

### Phase 4: Persistence Layer

```typescript
// feedback.repository.ts

type FeedbackEnrichment = {
  agentId: string;
  stepName: string;
  modelId: string | null;
  agentInput: string | null;
};

export async function insertFeedbackEntries(
  entityId: string,
  entries: FeedbackEntry[],
  enrichment: FeedbackEnrichment
): Promise<void> {
  if (entries.length === 0) return;
  await db.insert(agentFeedback).values(
    entries.map((entry) => ({
      id: generateId(),
      entityId,
      agentId: enrichment.agentId,
      stepName: enrichment.stepName,
      modelId: enrichment.modelId,
      agentInput: enrichment.agentInput,
      category: entry.category ?? null,
      feedback: entry.feedback,
      status: "open",
      archived: 0,
      createdAt: new Date(),
    }))
  );
}

type AgentFeedbackRecord = {
  id: string;
  entityId: string;
  entityTitle: string | null; // from LEFT JOIN — null if entity was deleted
  agentId: string;
  stepName: string;
  modelId: string | null;
  agentInput: string | null;
  feedback: string;
  category: string | null;
  status: "open" | "addressed";
  archived: number;
  adminNotes: string | null;
  addressedAt: Date | null;
  createdAt: Date;
};

export async function getFeedbackEntries(filters: {
  agentId?: string;
  category?: string;
  modelId?: string;
  archived?: boolean;
}): Promise<AgentFeedbackRecord[]> {
  const conditions = [eq(agentFeedback.archived, filters.archived ? 1 : 0)];
  if (filters.agentId)
    conditions.push(eq(agentFeedback.agentId, filters.agentId));
  if (filters.category)
    conditions.push(eq(agentFeedback.category, filters.category));
  if (filters.modelId)
    conditions.push(eq(agentFeedback.modelId, filters.modelId));

  return db
    .select({
      ...agentFeedback,
      entityTitle: yourEntity.title, // adapt field name to your entity
    })
    .from(agentFeedback)
    .leftJoin(yourEntity, eq(agentFeedback.entityId, yourEntity.id))
    .where(and(...conditions))
    .orderBy(desc(agentFeedback.createdAt));
}

export async function updateFeedbackStatus(
  id: string,
  status: "open" | "addressed",
  adminNotes?: string
): Promise<void> {
  await db
    .update(agentFeedback)
    .set({
      status,
      adminNotes: adminNotes ?? null,
      addressedAt: status === "addressed" ? new Date() : null,
    })
    .where(eq(agentFeedback.id, id));
}

export async function updateFeedbackArchived(
  id: string,
  archived: boolean
): Promise<void> {
  await db
    .update(agentFeedback)
    .set({ archived: archived ? 1 : 0 })
    .where(eq(agentFeedback.id, id));
}
```

**Validate:** Confirm batch insert works, filters behave correctly, and status
updates persist.

### Phase 5: API Endpoints

Expose three endpoints:

```
GET  /agent-feedback
     Query params: agentId, category, modelId, archived (boolean)
     Default: archived=false (inbox view excludes archived)
     Returns: feedback entries LEFT JOINed to entity table for display title

PATCH /agent-feedback/:id/status
     Body: { status: 'open' | 'addressed', adminNotes?: string }
     Sets addressedAt timestamp when marking addressed; clears it when reopening

PATCH /agent-feedback/:id/archive
     Body: { archived: boolean }
     Toggles archive state independently of status
```

**Why two PATCH endpoints?** Status and archive are separate workflows. A single
`/update` endpoint would require the client to pass the full record, risking
accidental overwrites of fields it didn't intend to change. Two focused
endpoints make intent explicit and prevent bugs.

**Validate:** Test each endpoint with curl or a REST client. Confirm default
inbox view excludes archived, and that the archived toggle can be reversed.

### Phase 6: Admin UI

> **Prototype available:** See `references/agent-feedback-mockup.html` for a
> clickable reference of the admin UI described below.

The UI has two areas: a filterable list and a detail panel.

**List panel responsibilities:**

- Render one row per feedback entry
- Show enough to scan without opening: feedback preview (truncated), agent ID,
  category, model, date, status indicator
- Support clicking to select an entry and open the detail panel
- Provide search (client-side fuzzy search across feedback text, entity title,
  agent ID, category)
- Filter dropdowns: by agent ID, by category — derived from distinct values in
  the current dataset
- Show archived toggle: when on, fetches again with `archived=true`
- Clear filters button

**Detail panel responsibilities:**

- Entity title + link to the entity in your main app — not because the feedback
  is _about_ the entity, but so the admin can open it and see what the agent was
  working on when it struggled. Omit this row if `entity_id` is not used.
- Full feedback text (with copy button)
- Collapsible agent input accordion (the full prompt — often long, so collapse
  by default)
- Status workflow:
  - If `open`: textarea for admin notes + "Mark as Addressed" button
  - If `addressed`: display admin notes (readonly) + "Reopen" button
- Archive toggle button (independent of status)

**Status workflow rationale:** Admin notes are captured at the moment of marking
as addressed, while the context is fresh. Displaying them read-only after
addressing serves as a log of what was done. Keeping "Reopen" available
acknowledges that addressed entries may need revisiting.

**Search implementation note:** Client-side fuzzy search (e.g., Fuse.js) works
well for feedback inboxes since the dataset is typically small (hundreds of
entries, not millions). Weight feedback text and entity title higher than
metadata fields. This avoids a server-side search endpoint.

**Composable pattern:**

```typescript
// useAgentFeedback.ts

export function useAgentFeedback() {
  const entries = ref<AgentFeedbackEntry[]>([]);
  const loading = ref(false);
  const showArchived = ref(false);

  async function fetchFeedback(filters?: FeedbackFilters) {
    loading.value = true;
    const res = await $fetch("/api/agent-feedback", {
      query: {
        ...filters,
        archived: showArchived.value ? true : undefined,
      },
    });
    entries.value = res.data;
    loading.value = false;
  }

  async function markAddressed(id: string, adminNotes?: string) {
    await $fetch(`/api/agent-feedback/${id}/status`, {
      method: "PATCH",
      body: { status: "addressed", adminNotes },
    });
    await fetchFeedback();
  }

  async function markOpen(id: string) {
    await $fetch(`/api/agent-feedback/${id}/status`, {
      method: "PATCH",
      body: { status: "open" },
    });
    await fetchFeedback();
  }

  async function toggleArchive(id: string, archived: boolean) {
    await $fetch(`/api/agent-feedback/${id}/archive`, {
      method: "PATCH",
      body: { archived },
    });
    await fetchFeedback();
  }

  return {
    entries,
    loading,
    showArchived,
    fetchFeedback,
    markAddressed,
    markOpen,
    toggleArchive,
  };
}
```

**Validate:** Open the admin UI, run an agent, confirm entries appear. Test the
full workflow: mark as addressed with a note, reopen, archive, toggle archived
view.

## Adapting to Different Tech Stacks

### Agentic Framework

| Framework  | How to register the tool                                   |
| ---------- | ---------------------------------------------------------- |
| Mastra     | Pass to `tools` in `createAgent()`                         |
| LangChain  | Add to agent's `tools` array                               |
| Direct SDK | Include in `tools` array in `client.messages.create()`     |
| MCP server | Register as a server tool; clients that connect inherit it |

The registry pattern is framework-agnostic — it's just a module with mutable
state. The tool's `execute` function calls `pushFeedbackEntry` regardless of how
the tool is invoked.

#### MCP Server Variant

When adding a feedback tool to an MCP server, several field mappings shift:

| Recipe field  | MCP equivalent                                                                                               |
| ------------- | ------------------------------------------------------------------------------------------------------------ |
| `entity_id`   | Optional — use when the agent is operating on a specific entity; omit for ad-hoc tool calls. See note below. |
| `step_name`   | Use the **tool name** that triggered the confusion (e.g., `search_documents`, `create_group`).               |
| `agent_input` | Capture the **tool's input arguments** (`params` passed to the handler), not the upstream prompt.            |
| `agent_id`    | MCP client or calling agent's identifier if available; otherwise a constant like `'mcp-client'`.             |

**`entity_id` in MCP context:** If the agent is using MCP tools to operate on a
specific entity (e.g., editing a document, updating a record), keep `entity_id`
as a correlation anchor — the same rationale as the original use case applies.
If the agent is making ad-hoc tool calls with no specific entity in context,
make it nullable or omit it entirely.

The registry pattern still works: the feedback tool pushes to the in-memory
registry during the MCP session, and persistence happens after the tool call
returns. The admin UI and triage workflow are identical — just drop the entity
column since there's nothing to link to.

### Database

| Database         | Adaptation                                                         |
| ---------------- | ------------------------------------------------------------------ |
| SQLite / Drizzle | Use as shown above                                                 |
| PostgreSQL       | Change `INTEGER` boolean to `BOOLEAN`, timestamps to `TIMESTAMPTZ` |
| MongoDB          | Store as documents; use a `status` index                           |
| Prisma           | Map schema to Prisma model; use `createMany` for batch insert      |

The `archived` field is stored as `INTEGER` (0/1) in SQLite. In PostgreSQL use
`BOOLEAN`. In document stores use a boolean field.

### Frontend Framework

The list + detail panel pattern is framework-agnostic. The composable example
above uses Vue 3 / Nuxt conventions, but the same shape works in React (as a
hook), Svelte (as a store), or any other framework.

## Gotchas & Important Notes

**Reset the registry at run start, not run end.** If an error occurs mid-run and
you only reset at the end, the next run starts dirty. Reset first thing.

**The model ID is often not what the frontend sent.** In systems where the model
is resolved server-side (e.g., "use the current default model for text
generation"), the frontend may not know the actual model ID. Resolve and capture
it in the step, not from the request.

**Don't make the feedback tool required in the agent prompt.** Phrasing it as
required causes agents to generate feedback even when they didn't struggle. The
quality of the signal drops dramatically. Make it conditional: "if you
encountered difficulties."

**Archive ≠ Delete ≠ Addressed.** Keep these three concepts separate:

- Addressed: admin has reviewed and acted
- Archived: hidden from default view (noise suppression)
- Deleted: permanent removal (usually only via cascade when entity is deleted)

**`entity_id` is a correlation anchor, not a subject link.** The feedback is
about the agent's process, not the entity itself. The entity title in the admin
UI exists so the admin can open the thing the agent was working on to understand
the context — not because the entity caused the problem. Keep this distinction
in mind when designing the UI: label it "Processing context" or "Was working
on:" rather than "Feedback about:". If your use case has no discrete processing
entity (e.g., an MCP server), make `entity_id` nullable and omit the entity
column from the admin UI entirely.

**LEFT JOIN for entity title in the API.** Don't make the admin look up the
entity separately — JOIN it in the query. The entity may have been deleted
(orphaned feedback), so use LEFT JOIN.

**Client-side search is fine until it isn't.** Fuse.js over a few hundred
entries is fast. If your feedback volume grows into the thousands, move search
server-side before it becomes a problem.

**Multiple feedback entries per run are normal.** An agent making 20 tool calls
might call `reportFeedback` 3 times for different issues. The batch insert
handles this naturally. Don't assume one entry per run.

## Future Extensions

Once the base system is established, consider these extensions based on observed
usage:

- **Tool interaction capture:** Record tool calls made during the run (tool ID,
  input, output, timestamp) and surface as a timeline in the detail panel.
  Reveals which tools contributed to the agent's confusion.
- **Structured category schema:** After observing natural freeform patterns,
  introduce a formal category enum to enable better aggregation.
- **Aggregate analytics:** Heatmap of which agents/steps generate the most
  feedback. Useful for prioritizing prompt iteration.
- **Extend to more agents:** Once the pattern is proven on one agent, add the
  tool to other agents with minimal changes (just a new `agentId` constant).
