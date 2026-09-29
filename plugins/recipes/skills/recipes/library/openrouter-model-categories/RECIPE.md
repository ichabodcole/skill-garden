# OpenRouter Model Categories Recipe

## Purpose

Build a category-based abstraction layer for AI model management. Instead of
hardcoding specific model IDs throughout an application, this system lets
administrators assign models to semantic categories (e.g., "default", "fast",
"creative", "deep-thinker") via an admin UI. Client applications reference
categories, not model IDs, so a model swap requires only an admin panel change
-- no code changes, no redeployment.

This recipe is a hybrid: the model discovery and metadata are
OpenRouter-specific (using their `/api/v1/models` endpoint), but the
category-to-model mapping pattern works with any model provider API.

## When to Use

- Apps that use AI models and need admin-controlled model selection
- When you want to swap AI models without redeploying client applications
- When different use cases need different models (fast vs. powerful vs.
  creative)
- When you need a searchable model browser for non-technical admins
- Any system where model selection should be a runtime configuration, not a
  build-time decision

## Technology Stack

| Layer      | Technology                  | Purpose                         |
| ---------- | --------------------------- | ------------------------------- |
| Model API  | OpenRouter `/api/v1/models` | Model discovery and metadata    |
| Validation | Zod                         | Runtime validation of API data  |
| Database   | PostgreSQL + Drizzle ORM    | Category-to-model persistence   |
| API Server | Elysia (Bun)                | Admin + client-facing routes    |
| Admin UI   | Nuxt/Vue 3 + shadcn-vue     | Model browser and category mgmt |
| Search     | Fuse.js                     | Fuzzy model search              |

## Architecture Overview

```
Client Apps                          Admin Panel
(Desktop, Mobile, API)               (Web UI)
      │                                  │
      │ GET /api/ai/models               │ GET /api/admin/ai-models/available
      │ → [{name, description}]          │ → [{id, name, pricing, ...}]
      │                                  │
      │ POST /api/ai/transform           │ PUT /api/admin/ai-models/:category
      │   category: "creative"           │   {modelId, description}
      │                                  │
      ▼                                  ▼
┌──────────────────────────────────────────────┐
│              API Server                       │
│                                               │
│  ┌─────────────────────┐  ┌────────────────┐ │
│  │ ModelConfigService   │  │ OpenRouterClient│ │
│  │ (category → modelId) │  │ (model catalog) │ │
│  │ [1-min cache]        │  │ [5-min cache]   │ │
│  └──────────┬──────────┘  └────────┬───────┘ │
│             │                      │          │
│             ▼                      ▼          │
│     ┌──────────────┐    ┌──────────────────┐  │
│     │  PostgreSQL   │    │  OpenRouter API   │  │
│     │  (categories) │    │  (model catalog)  │  │
│     └──────────────┘    └──────────────────┘  │
└───────────────────────────────────────────────┘
```

### Core Design Decision: Category Abstraction

The central idea is a **layer of indirection** between what client apps ask for
and what model actually runs:

```
Client says:  "Use the creative model"
Service maps: "creative" → "anthropic/claude-sonnet-4-20250514"
OpenRouter:    Executes with that specific model
```

If you later decide a different model is better for creative tasks, change the
mapping in the admin panel. Every client immediately uses the new model. No code
changes. No redeployments.

**Why categories instead of direct model IDs?**

- **Decoupling:** Client code never contains model IDs that go stale
- **Non-technical control:** Admins swap models via UI, not code
- **Multi-model support:** Different categories for different jobs (fast for
  quick tasks, powerful for complex reasoning, creative for content generation)
- **Graceful fallback:** If a category has no mapping, a default model is used

**What this avoids:**

- **Not a model proxy.** This doesn't route or transform API calls. It only
  resolves "which model should I use for this category?" Your existing AI
  execution layer (agent framework, direct API call) handles the actual model
  interaction.
- **Not a multi-provider router.** This resolves categories to OpenRouter model
  IDs. If you need to route between OpenRouter, Ollama, and other backends, see
  the `ai-provider-factory` recipe for that layer.

**Trade-offs:**

- Simple 1:1 category-to-model mapping. No A/B testing, no weighted
  distribution, no fallback chains. If you need those, extend the data model.
- Categories are stored in the API database, not in client apps. Clients need
  network access to resolve categories (or cache them).
- The admin must know enough about models to make good assignments. The UI helps
  by showing pricing, context window, and capabilities.

---

## Data Model

A single table with category as the primary key. Intentionally minimal.

### Schema

```sql
CREATE TABLE ai_model_settings (
  category    TEXT PRIMARY KEY,       -- e.g., "default", "fast", "creative"
  model_id    TEXT NOT NULL,          -- OpenRouter model ID, e.g., "openai/gpt-4o-mini"
  description TEXT,                   -- Human-readable description for clients
  updated_at  TIMESTAMP NOT NULL DEFAULT NOW()
);
```

```
ai_model_settings
┌────────────┬──────────────────────────────────────┬─────────────────────┬────────────┐
│ category   │ model_id                             │ description         │ updated_at │
├────────────┼──────────────────────────────────────┼─────────────────────┼────────────┤
│ default    │ openai/gpt-4o-mini                   │ General purpose     │ 2025-03-01 │
│ creative   │ anthropic/claude-sonnet-4-20250514   │ Creative writing    │ 2025-03-01 │
│ fast       │ google/gemini-2.0-flash-001          │ Quick responses     │ 2025-03-01 │
│ vision     │ openai/gpt-4o                        │ Image understanding │ 2025-03-01 │
└────────────┴──────────────────────────────────────┴─────────────────────┴────────────┘
```

**Why category as primary key?** Each category maps to exactly one model. The
upsert pattern (insert or update on conflict) makes creating and updating a
category the same operation.

**Why `description` on the category, not on the model?** The description
explains what this category is _for_ in your application, not what the model
_is_. "Fast model for quick edits" is more useful to client developers than
"GPT-4o Mini is a small model from OpenAI."

### Drizzle ORM Definition

```typescript
import { pgTable, text, timestamp } from "drizzle-orm/pg-core";

export const aiModelSettings = pgTable("ai_model_settings", {
  category: text("category").primaryKey(),
  modelId: text("model_id").notNull(),
  description: text("description"),
  updatedAt: timestamp("updated_at").notNull().defaultNow(),
});

export type AIModelSetting = typeof aiModelSettings.$inferSelect;
export type AIModelSettingInsert = typeof aiModelSettings.$inferInsert;
```

---

## Service Layer

Two services with different responsibilities and cache durations.

### OpenRouter Client

Fetches the full model catalog from OpenRouter's API. Results are cached
in-memory to avoid hitting the API on every admin page load.

```
OpenRouterClient
├── getAvailableModels() → OpenRouterModel[]  [5-min cache]
└── clearCache()                               [for testing]
```

**Key behaviors:**

1. **5-minute in-memory cache.** The model catalog changes infrequently. Caching
   prevents redundant API calls when admins browse the model list.
2. **Zod validation on every model.** OpenRouter returns hundreds of models.
   Some may have unexpected shapes (missing fields, null where you expect a
   value). Validate each model with `safeParse`, keep valid ones, log invalid
   ones. Do NOT let one bad model break the entire list.
3. **5-second request timeout.** OpenRouter's model list is large (~300+
   models). If the API is slow, fail fast rather than hanging.
4. **Optional auth header.** The model list endpoint works without
   authentication, but sending the API key may grant access to models not in the
   public catalog.

### Model Config Service

Manages category-to-model mappings in the database with read-through caching.

```
AIModelConfigService
├── getModelForCategory(category) → modelId    [1-min cache + fallback]
├── updateModelConfig(category, modelId, description?) → config
├── getAllConfigs() → config[]
├── getConfig(category) → config | null
└── clearCache()                                [for testing]
```

**Key behaviors:**

1. **1-minute read-through cache per category.** AI operations may call
   `getModelForCategory` frequently. The cache avoids a database query on every
   request. The short TTL means admin changes propagate within a minute.
2. **Fallback to DEFAULT_MODEL constant.** If a category has no database entry,
   return a sensible default (e.g., `"openai/gpt-4o-mini"`). This means the
   system works even with an empty database -- no setup required before first
   use.
3. **Error resilience.** If the database query fails, log the error and return
   the default model. An AI operation should degrade gracefully, not crash
   because the config table is unreachable.
4. **Cache invalidation on write.** After `updateModelConfig`, delete the cached
   entry for that category so the next read gets fresh data.
5. **Upsert pattern.** `updateModelConfig` uses INSERT ... ON CONFLICT UPDATE.
   Creating a new category and updating an existing one are the same operation.

---

## API Routes

### Client-Facing Route (No Auth Required)

Returns the list of configured categories. Clients use this to know what
categories exist and present them to users.

```
GET /api/ai/models
Response: {
  categories: [
    { name: "default", description: "General purpose model" },
    { name: "creative", description: "Creative writing and content" },
    { name: "fast", description: "Quick responses for simple tasks" }
  ]
}
```

**Why a separate route from admin?** Clients only need category names and
descriptions. They should NOT see model IDs, pricing, or architecture details.
The category abstraction is the whole point -- clients reference categories, not
models.

### Admin Routes (Auth + Admin Role Required)

Four endpoints for category management:

```
GET  /api/admin/ai-models              → List all category configurations
GET  /api/admin/ai-models/available    → Fetch model catalog from OpenRouter
GET  /api/admin/ai-models/:category    → Get specific category config
PUT  /api/admin/ai-models/:category    → Update category → model mapping
```

**`GET /available` response shape:**

```typescript
{
  models: [{
    id: string,              // "openai/gpt-4o-mini"
    name: string,            // "GPT-4o Mini"
    description: string,     // Model description
    contextLength: number,   // Max tokens
    pricing: {
      prompt: string,        // Per-token price as string (e.g., "0.00000015")
      completion: string,
      image?: string,
      request?: string,
    },
    architecture: {
      input_modalities: string[],   // ["text", "image"]
      output_modalities: string[],  // ["text"]
      tokenizer: string,
      instruct_type: string | null,
    },
  }]
}
```

**`PUT /:category` request/response:**

```typescript
// Request
{ modelId: string, description?: string }

// Response
{ category: string, modelId: string, description: string | null, updatedAt: string }
```

The PUT endpoint uses the model config service's upsert, so it handles both
creating new categories and updating existing ones.

---

## OpenRouter Model Schema (Zod)

OpenRouter returns rich metadata per model. Define a Zod schema to validate and
type the response:

```typescript
import { z } from "zod";

export const openRouterModelSchema = z.object({
  id: z.string(),
  name: z.string(),
  created: z.number(),
  description: z.string(),
  architecture: z.object({
    input_modalities: z.array(z.string()),
    output_modalities: z.array(z.string()),
    tokenizer: z.string(),
    instruct_type: z.string().nullable(),
  }),
  top_provider: z.object({
    is_moderated: z.boolean(),
    context_length: z.number().nullable(),
    max_completion_tokens: z.number().nullable(),
  }),
  pricing: z.object({
    prompt: z.string(),
    completion: z.string(),
    image: z.string().optional(),
    request: z.string().optional(),
    web_search: z.string().optional(),
    internal_reasoning: z.string().optional(),
    input_cache_read: z.string().nullable().optional(),
    input_cache_write: z.string().nullable().optional(),
  }),
  context_length: z.number().nullable(),
  hugging_face_id: z.string().nullable(),
  per_request_limits: z.record(z.string(), z.any()).nullable(),
  supported_parameters: z.array(z.string()).nullable(),
});

export type OpenRouterModel = z.infer<typeof openRouterModelSchema>;
```

**Why validate every model?** OpenRouter's catalog has hundreds of models from
dozens of providers. Some models have missing or malformed fields. Without
validation, one bad model crashes the entire admin UI. With `safeParse` per
model, bad entries are silently filtered and logged.

---

## Implementation Process

### Phase 1: Data Model and Migration

1. Define the `ai_model_settings` table schema using your ORM
2. Generate and run the migration
3. Define a `DEFAULT_MODEL` constant (e.g., `"openai/gpt-4o-mini"`) used as
   fallback when no category mapping exists

**Validate:** Migration runs. Table exists with correct columns.

### Phase 2: OpenRouter Client

1. Create the Zod schema for OpenRouter model responses
2. Implement the `OpenRouterClient` class:
   - Static class-level cache (models + timestamp)
   - 5-minute cache TTL
   - `getAvailableModels()` method with fetch + timeout + Zod validation
   - `clearCache()` static method
3. Export a singleton instance

**Key implementation detail:** Use `safeParse` on each model in a loop, not
`parse` on the array. This way one invalid model doesn't reject the entire
catalog:

```typescript
const validatedModels: OpenRouterModel[] = [];
for (const model of data.data) {
  const result = openRouterModelSchema.safeParse(model);
  if (result.success) {
    validatedModels.push(result.data);
  } else {
    // Log but don't throw
  }
}
```

**Validate:** Client fetches models. Invalid models are filtered. Cache works
(second call returns instantly).

### Phase 3: Model Config Service

1. Implement `AIModelConfigService` class:
   - Instance-level `Map<string, { model, timestamp }>` cache
   - 1-minute cache TTL
   - `getModelForCategory()` with cache check → DB query → fallback
   - `updateModelConfig()` with upsert + cache invalidation
   - `getAllConfigs()` and `getConfig()` for admin reads
2. Export a singleton instance

**Critical ordering in `getModelForCategory`:**

```
1. Check cache → return if fresh
2. Query database → return + cache if found
3. Fallback to DEFAULT_MODEL (no error, just degrade)
```

Never throw from `getModelForCategory`. AI operations depend on this. A database
outage should degrade to the default model, not crash the request.

**Validate:** Service returns default model with empty DB. After update, returns
configured model. Cache invalidates correctly on update.

### Phase 4: API Routes

1. **Client route** (`GET /api/ai/models`):
   - No auth required
   - Returns `{ categories: [{ name, description }] }`
   - Maps from `getAllConfigs()`

2. **Admin routes** (behind auth + admin role guard):
   - `GET /` → `getAllConfigs()` mapped to response shape
   - `GET /available` → `openRouterClient.getAvailableModels()` mapped to
     simplified shape (id, name, description, contextLength, pricing,
     architecture)
   - `GET /:category` → `getConfig()` with 404 if not found
   - `PUT /:category` → `updateModelConfig()` with validated body

**Validate:** Routes return correct data. Admin routes reject unauthenticated
requests. PUT creates and updates categories. Client route does not expose model
IDs.

### Phase 5: Admin UI

The admin UI is a single page with three sections. Open the reference prototype
at `references/ai-models-admin-mockup.html` for the full interactive layout —
use the state switcher to see each UI state.

**Page structure:**

- **Categories table** (top) — configured categories with name badge, model ID,
  description, last updated, and actions (info, edit, delete)
- **Model catalog** (bottom) — searchable, sortable list of all OpenRouter
  models
- **Model detail pane** (right sidebar, sticky) — shows selected model's full
  details and "Select This Model" assignment button

**Key UX patterns:**

- **Info icon on categories:** Clicking the info icon on a category row
  auto-selects that category's assigned model in the catalog below, showing its
  details in the sidebar. This saves the admin from searching for it manually.
- **Add Category with pre-selected model:** If the admin has a model selected in
  the detail pane when they click "Add Category", that model is pre-filled as
  the default assignment. If no model is selected, the system's `DEFAULT_MODEL`
  is used. This lets admins browse first, then create a category for the model
  they found.
- **Model visibility:** Admins can hide models from the catalog via an eye icon
  per row (persisted in localStorage). A three-state filter (all/visible/hidden)
  controls which models are shown.
- **Description search toggle:** A toggle button expands fuzzy search to include
  model descriptions, not just names and IDs. Useful when name search is too
  narrow.

**Data flow for model selection:**

```
1. Admin clicks model in catalog → detail pane shows full info
2. Admin clicks "Select This Model" → PUT /:category saves assignment
3. Categories table refreshes to show new model mapping
```

**Validate:** Search filters models. Sort works. Selecting a model saves
correctly. Detail pane shows accurate data.

### Phase 6: Integration with AI Operations

Wire the category system into your AI execution layer. When performing an AI
operation, resolve the category to a model ID before making the API call:

```
1. Client sends: POST /api/ai/transform { category: "creative", ... }
2. Route handler calls: modelConfigService.getModelForCategory("creative")
3. Service returns: "anthropic/claude-sonnet-4-20250514" (from DB or default)
4. Handler passes modelId to your AI execution layer
5. AI layer makes the actual OpenRouter API call with that model
```

The category is optional in the request. If omitted, use "default". This way
existing clients work without changes -- they get the default category's model.

**Validate:** AI operations use the configured model for each category. Changing
a category's model in the admin panel changes what model AI operations use
(within the cache TTL).

---

## Integration Points

### Client Applications

Client apps fetch the categories list from `GET /api/ai/models` and present them
to users. The category list drives dropdowns, radio buttons, or automatic
selection based on the task type.

Clients never see or reference model IDs. They send a category name with their
AI requests. This is the key architectural benefit -- clients are completely
insulated from model changes.

### AI Execution Layer

Your AI execution layer (agent framework, direct API calls, etc.) receives a
model ID from the config service, not a category. The category-to-model
resolution happens at the API boundary, before the AI call is made.

This means the AI execution layer is category-unaware. It just takes a model ID
and runs it. The category system is purely an administrative concern.

### Admin Authentication

Admin routes must be protected. The pattern:

```typescript
const adminRoutes = new Elysia({ prefix: "/admin/ai-models" }).use(
  requireAdmin
); // Middleware that checks session + admin role
// ... routes
```

The client-facing route (`GET /api/ai/models`) does NOT require admin access.
Any authenticated user (or even unauthenticated, depending on your auth model)
can read the category list.

---

## Settings / Configuration

| Setting               | Type   | Default                | Purpose                                    |
| --------------------- | ------ | ---------------------- | ------------------------------------------ |
| `DEFAULT_MODEL`       | string | `"openai/gpt-4o-mini"` | Fallback when no category mapping exists   |
| `OPEN_ROUTER_API_KEY` | string | `undefined`            | Optional; enables authenticated model list |
| Model cache TTL       | number | 5 minutes              | How long to cache the OpenRouter catalog   |
| Config cache TTL      | number | 1 minute               | How long to cache category → model lookups |
| Request timeout       | number | 5 seconds              | Timeout for OpenRouter API calls           |

---

## Adapting to Different Tech Stacks

### Different Model Provider APIs

The category abstraction works with any model provider. Replace
`OpenRouterClient` with a client for your provider:

- **OpenAI:** Fetch from `/v1/models`. Simpler schema (no pricing field).
- **Anthropic:** No model list API. Hardcode known models or maintain a static
  list.
- **Ollama:** Fetch from `http://localhost:11434/api/tags`. Local models, no
  pricing.
- **Multiple providers:** Merge model lists from several providers into one
  catalog. Add a `provider` field to distinguish them.

### Different Databases

The schema is trivial SQL. Adapt to any database:

- **SQLite:** Same schema, use `TEXT` types. Good for local-first apps.
- **MongoDB:** Document with `_id: category`, `modelId`, `description`,
  `updatedAt`.
- **Key-value store:** Key = category name, value = `{ modelId, description }`.

### Different API Frameworks

The route structure is framework-agnostic:

- **Express:** `router.get('/admin/ai-models', handler)`
- **Fastify:** `fastify.get('/admin/ai-models', handler)`
- **Next.js API Routes:** `app/api/admin/ai-models/route.ts`
- **Hono:** `app.get('/admin/ai-models', handler)`

### Different Admin UI Frameworks

The admin UI pattern (categories + model catalog + detail pane) works in any
framework. The reference prototype at `references/ai-models-admin-mockup.html`
provides the canonical layout and states — adapt to your framework:

- **React:** Fuse.js and TanStack Table both have React adapters.
- **Svelte:** Same component structure. Use Svelte stores instead of Vue refs.
- **Plain HTML + htmx:** Server-render the model list, use htmx for search and
  selection.

---

## Gotchas & Important Notes

- **OpenRouter pricing is in strings, not numbers.** Model pricing values like
  `"0.00000015"` must stay as strings through most of the system. JavaScript
  floating-point math will mangle very small values. Only convert to number for
  sorting and display. When displaying, use `toFixed(20)` then trim trailing
  zeros to avoid scientific notation (e.g., `1.5e-7` → `$0.00000015`).

- **Validate each model individually, not the array.** OpenRouter returns 300+
  models. If you validate the entire array and one model is malformed, you lose
  all of them. Use `safeParse` per model, log failures, and return the valid
  subset.

- **The client-facing route must NOT expose model IDs.** The whole point of
  categories is abstraction. If clients can see model IDs, developers will
  hardcode them and bypass the category system. Return only
  `{ name, description }`.

- **Cache invalidation must happen synchronously with writes.** After
  `updateModelConfig`, delete the cache entry BEFORE returning. If you
  invalidate asynchronously, a concurrent read between the write and the
  invalidation returns stale data.

- **New categories don't exist in the database until a model is assigned.** The
  admin creates a category name, but nothing is persisted until they assign a
  model. Handle the new-category case gracefully (show "No model selected").

- **The OpenRouter model list is public.** You can fetch it without an API key.
  But sending the key may surface models not in the public catalog. Always send
  the key if available.

- **Sort models by prompt price, not completion price.** Prompt tokens are
  typically the dominant cost driver. Sorting by prompt price gives the most
  useful cost comparison.

- **Fuse.js threshold of 0.3 works well for model names.** Too strict (0.1) and
  users miss models with slight typos. Too loose (0.6) and unrelated models
  appear. 0.3 is a good balance.

- **See the reference prototype for UI states and layout.** The prototype at
  `references/ai-models-admin-mockup.html` shows all key states: empty detail
  pane, current model view, model selection, add/edit modals, search filtering,
  and hidden model filtering. Use it as a starting point for implementation.
