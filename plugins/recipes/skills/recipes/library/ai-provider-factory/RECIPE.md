# AI Provider Factory Recipe

## Purpose

Implement a provider abstraction layer that lets an application use multiple
AI/LLM backends (cloud APIs, local inference servers, self-hosted models)
through a single unified interface. A factory function creates the correct
provider instance based on a provider ID and configuration, so the rest of the
application never needs to know which backend is active.

This recipe is technology-agnostic at the architecture level. The interface
design, factory pattern, and configuration model work with any language,
framework, or AI SDK. The concepts apply whether you are building a desktop app,
web app, mobile app, or server-side service.

## When to Use

- Any app that needs to support more than one AI/LLM backend
- Products where users choose between cloud APIs (OpenRouter, OpenAI) and local
  inference (Ollama, LM Studio)
- Apps that use different models for different tasks (fast model for simple
  work, powerful model for complex work)
- When you want to add new AI providers without changing existing business logic
- Apps that need to validate provider credentials before use (test connection,
  verify API keys)

## Architecture Overview

### Core Concept: Provider Interface + Factory Function

Every AI provider implements the same abstract interface. Application code never
instantiates providers directly -- it calls a factory function with a provider
ID and configuration, and gets back an object that satisfies the interface.

```
Application Code
       │
       ▼
┌─────────────────────┐
│   Factory Function   │  createProvider(providerId, config) → Provider
│  (switch on ID)      │
└──────┬──────┬───────┘
       │      │
       ▼      ▼
┌──────────┐ ┌──────────┐ ┌──────────┐
│ Cloud    │ │ Local    │ │ Custom   │
│ Provider │ │ Provider │ │ Provider │
│(API key) │ │(base URL)│ │  (...)   │
└──────────┘ └──────────┘ └──────────┘
       │           │            │
       ▼           ▼            ▼
   OpenRouter   Ollama      Your own
   OpenAI       LM Studio   endpoint
```

### Provider Categories

Providers fall into two categories with different configuration requirements:

| Category | Auth       | Discovery         | Examples                      |
| -------- | ---------- | ----------------- | ----------------------------- |
| Cloud    | API key    | HTTP to vendor    | OpenRouter, OpenAI, Anthropic |
| Local    | None / URL | HTTP to localhost | Ollama, LM Studio, vLLM       |

This distinction matters for configuration, validation, and UI. Cloud providers
need API key management and validation. Local providers need server URL
configuration and connectivity checks.

### Why This Design?

**Problem it solves:** Application logic (chat, content transformation, document
operations) should not care which AI backend is active. Users should be able to
switch providers without touching business logic. Adding a new provider should
require implementing one class and registering it in the factory.

**What it avoids:**

- **Not a universal AI SDK.** This is not an attempt to unify every AI API
  difference. Provider-specific features (like OpenRouter's model marketplace or
  Ollama's model pulling) live on the concrete implementations, not the
  interface.
- **Not a routing/load-balancing layer.** The factory creates one provider at a
  time based on user configuration. It does not distribute requests across
  multiple providers simultaneously.
- **Not an agent framework.** This handles the "which backend do I talk to?"
  question. Agent orchestration, tool calling, and multi-step reasoning are
  separate concerns that sit on top of this layer.

**Trade-offs:**

- Unified interface means lowest-common-denominator features. Provider-specific
  capabilities require type narrowing or optional methods.
- Each provider stores its own config (API key OR base URL), so settings grow
  linearly with provider count.
- Connection testing adds latency to initial setup but prevents cryptic errors
  during actual use.

---

## Provider Interface

The abstract interface defines the contract every provider must satisfy. This is
the single most important artifact in the system -- everything else flows from
it.

### Required Methods

```
ProviderService (abstract)
├── testConnection()      → ConnectionResult
├── getAvailableModels()  → Model[]
├── generateContent(options) → string
├── validateConfig()      → boolean
└── getProviderInfo()     → ProviderInfo
```

#### `testConnection() → ConnectionResult`

Validates that the provider is reachable and credentials are correct. For cloud
providers, this typically sends a minimal request (e.g., a cheap completion with
a test prompt). For local providers, this pings the server and lists models.

**Return type:**

```
ConnectionResult {
  success: boolean
  error?: string
  responseTime?: number     // milliseconds
  modelTested?: string      // which model was used for the test
  timestamp: string         // ISO timestamp
}
```

**Why this exists:** Users configure API keys and server URLs in settings.
Without an explicit test step, the first error they see is a cryptic failure
during actual use. Test-before-use is a much better UX.

#### `getAvailableModels() → Model[]`

Returns the list of models available from this provider. Cloud providers call
their model listing API. Local providers query the running server.

**Return type:**

```
Model {
  id: string                // Unique model identifier (e.g., "openai/gpt-4o-mini")
  name: string              // Human-readable name
  description?: string      // Optional description or capability summary
  context_length?: number   // Max context window in tokens
  provider: ProviderID      // Which provider this model belongs to
  raw?: any                 // Provider-specific raw data (pricing, architecture, etc.)
}
```

**Why `raw` exists:** Different providers return wildly different metadata
(OpenRouter includes pricing tiers; Ollama includes quantization levels). Rather
than trying to normalize everything, keep the raw response available for
provider-specific UI.

#### `generateContent(options) → string`

The core generation method. Sends a chat completion request and returns the
response text.

**Parameters:**

```
{
  model: string              // Model ID to use
  messages: Message[]        // Chat messages array
  maxTokens?: number         // Max tokens in response
  temperature?: number       // Sampling temperature (0.0 - 1.0)
}

Message {
  role: 'system' | 'user' | 'assistant'
  content: string
}
```

**Important design decision:** This returns a plain string, not a stream. If
your application needs streaming, add a separate `streamContent()` method that
returns an async iterator or readable stream. Do not overload `generateContent`
with both behaviors -- the calling code and error handling are fundamentally
different.

#### `validateConfig() → boolean`

Synchronous check that the provider's configuration is structurally valid (API
key present and correctly formatted, base URL is a valid HTTP URL, etc.). This
does NOT make network calls -- it checks configuration shape only.

**Examples:**

- Cloud provider: API key is non-empty and matches expected prefix (e.g.,
  `sk-or-` for OpenRouter)
- Local provider: Base URL starts with `http://` or `https://`

#### `getProviderInfo() → ProviderInfo`

Returns static metadata about the provider.

```
ProviderInfo {
  id: ProviderID            // Enum value identifying this provider
  name: string              // Display name ("OpenRouter", "Ollama")
  requiresApiKey: boolean   // Whether this provider needs an API key
  requiresUrl: boolean      // Whether this provider needs a base URL
}
```

### Base Class Utilities

The abstract base class should also provide shared helper methods that concrete
providers inherit:

- **`makeRequest(url, options) → { success, data?, error? }`** - HTTP wrapper
  with error handling and JSON parsing. Saves each provider from reimplementing
  fetch-and-parse.
- **`withTiming(operation) → { result, responseTime }`** - Wraps an async
  operation and measures wall-clock time. Used by `testConnection` to report
  response times.

---

## Factory Function

The factory is intentionally simple -- a switch statement on the provider ID. No
dependency injection containers, no plugin registries, no dynamic loading. A
switch statement is easy to read, easy to test, and the number of providers is
small enough that scaling is not a concern.

### Structure

```
function createProviderService(providerId, config) → ProviderService:
  switch (providerId):
    case 'openrouter':
      VALIDATE: config must include apiKey (throw if missing)
      return new OpenRouterService(config)

    case 'ollama':
      return new OllamaService(config)  // baseUrl has a default

    case 'lmstudio':
      return new LMStudioService(config)  // baseUrl has a default

    default:
      throw "Unknown AI provider: {providerId}"
```

### Key Decisions

**Validate at creation time, not at call time.** If a cloud provider requires an
API key, the factory throws immediately when the key is missing -- not when the
first API call fails five minutes later. This is a fail-fast pattern.

**Local providers have sensible defaults.** Ollama defaults to
`http://localhost:11434`, LM Studio to `http://localhost:1234`. Users only need
to change these if they are running non-standard configurations.

**The factory takes a flat config object.** `{ apiKey?, baseUrl? }` -- not
nested per-provider config. The factory knows which fields to extract. This
keeps the calling code simple: it does not need to know the shape of each
provider's config.

---

## Configuration & Settings

### Settings Data Model

Each provider stores its own configuration in a typed settings object. The
top-level settings structure tracks which provider is currently selected.

```
AISettings {
  selectedProvider: ProviderID        // Currently active provider

  cloudProvider: CloudProviderSettings {
    providerID: ProviderID
    apiKey: string
    isApiKeyValid: boolean            // Cached validation state
    selectedModel: string             // Model ID for this provider
    lastValidatedAt?: string          // ISO timestamp of last successful test
  }

  localProviderA: LocalProviderSettings {
    providerID: ProviderID
    serverUrl: string                 // e.g., "http://localhost:11434"
    isConnectionValid: boolean        // Cached connection state
    selectedModel: string             // Model ID for this provider
    lastValidatedAt?: string
  }

  localProviderB: LocalProviderSettings { ... }

  preferences: {
    autoLoadModels: boolean           // Load models on startup
    requestTimeout: number            // Seconds before timing out
  }
}
```

### Type Guards for Provider Categories

Use discriminated types and type guards to safely narrow provider settings:

```
CloudProviderSettings has: apiKey, isApiKeyValid
LocalProviderSettings has: serverUrl, isConnectionValid

isCloudProvider(settings) → settings is CloudProviderSettings
  check: 'apiKey' in settings

isLocalProvider(settings) → settings is LocalProviderSettings
  check: 'serverUrl' in settings
```

This lets shared code (like the configuration builder) handle both categories
without provider-specific branching:

```
if isLocalProvider(settings):
  config.baseUrl = settings.serverUrl
else if isCloudProvider(settings):
  config.apiKey = settings.apiKey
```

### Provider Registry

A static array defines the available providers with their metadata. This drives
the settings UI without hardcoding provider details in components:

```
AVAILABLE_PROVIDERS = [
  { id: 'openrouter',  name: 'OpenRouter',  type: 'cloud', requiresApiKey: true,  requiresUrl: false, description: '...' },
  { id: 'ollama',      name: 'Ollama',      type: 'local', requiresApiKey: false, requiresUrl: true,  description: '...' },
  { id: 'lmstudio',    name: 'LM Studio',   type: 'local', requiresApiKey: false, requiresUrl: true,  description: '...' },
]
```

**Why a static array instead of deriving from the factory?** The registry
includes UI metadata (descriptions, enabled flags) that the factory does not
need. Keeping them separate avoids coupling UI concerns to the service layer.

---

## Implementation Process

### Phase 1: Provider Interface and Base Class

Define the abstract interface and base class with shared utilities.

1. Create the provider ID enum with one entry per supported backend
2. Define the `Model`, `ConnectionResult`, and `ProviderInfo` types
3. Implement the abstract base class with `makeRequest` and `withTiming` helpers
4. Define the settings types (`CloudProviderSettings`, `LocalProviderSettings`,
   `AISettings`)
5. Implement type guards (`isCloudProvider`, `isLocalProvider`)

**Validate:** Types compile. Base class can be instantiated by a trivial
subclass.

### Phase 2: First Provider Implementation (Cloud)

Implement a cloud provider (e.g., OpenRouter or OpenAI) as the reference
implementation.

1. Extend the base class
2. Implement `testConnection` -- send a cheap completion, check for valid
   response
3. Implement `getAvailableModels` -- call the models API, normalize to `Model[]`
4. Implement `generateContent` -- send chat completion, extract response text
5. Implement `validateConfig` -- check API key format
6. Implement `getProviderInfo` -- return static metadata
7. Add provider-specific error mapping (401 → "Invalid API key", 429 → "Rate
   limited", etc.)

**Validate:** Can test connection, list models, and generate content with a
valid API key. Invalid key produces a clear error message.

### Phase 3: Local Provider Implementation

Implement a local provider (e.g., Ollama or LM Studio).

1. Extend the base class
2. Implement `testConnection` -- ping the server, list available models
3. Implement `getAvailableModels` -- query the local server's model list
4. Implement `generateContent` -- send chat request to local endpoint
5. Implement `validateConfig` -- check that base URL is a valid HTTP URL
6. Default the base URL to the standard localhost port

**Security note for desktop/Electron apps:** Local provider HTTP calls should go
through a privileged process (main process / IPC bridge), not directly from the
renderer. The renderer service calls an IPC channel, and the main process makes
the actual HTTP request. This prevents renderer-process network access and
enables URL validation on the trusted side.

**Validate:** Can connect to a running local server, list its models, and
generate content.

### Phase 4: Factory Function

1. Implement the factory switch statement
2. Add creation-time validation (throw for missing API keys on cloud providers)
3. Write tests covering:
   - Each provider ID creates the correct service class
   - Missing required config throws immediately
   - Unknown provider ID throws
   - Configuration is passed through correctly

**Validate:** All factory tests pass. Unknown providers produce clear errors.

### Phase 5: Settings Store Integration

Wire the factory into the application's state management layer.

1. Create a settings store that persists `AISettings`
2. Implement `loadSettings` -- reads persisted settings, deep-merges with
   defaults
3. Implement `saveSettings` -- persists current settings
4. Implement `loadProviderModels(providerId)` -- creates a service via the
   factory, calls `getAvailableModels`, stores the result
5. Implement `testConnection(providerId)` -- creates a service via the factory,
   calls `testConnection`, updates validation state
6. Implement `switchProvider(providerId)` -- updates `selectedProvider`, clears
   stale model lists

**Important ordering:**

1. Load settings first (so config is available)
2. Then auto-load models if the stored provider has valid credentials
3. Settings changes trigger re-validation when relevant config changes

**Validate:** Settings persist across restarts. Switching providers loads the
correct model list. Invalid credentials show clear errors.

### Phase 6: Configuration Builder

Create a helper that reads the current store state and produces the config
object needed by the rest of the application (e.g., for sending to an agent
framework or API).

1. Validate current configuration (provider selected, model selected,
   credentials present)
2. Build a flat config object: `{ modelId, providerId, apiKey?, baseUrl? }`
3. Use type guards to extract the right fields from provider settings
4. Throw with a clear message if validation fails

This is the bridge between "user configured their AI settings" and "application
code needs to make an AI call."

**Validate:** Builder produces correct config for each provider type. Missing
config produces actionable error messages.

---

## Integration Points

### Settings UI

The settings UI should be driven by the provider registry, not hardcoded. The
pattern:

1. **Provider picker:** Render the `AVAILABLE_PROVIDERS` list. Selecting a
   provider updates `selectedProvider` in settings.
2. **Per-provider config panel:** Based on the selected provider's `type`:
   - Cloud: Show API key input + "Test Key" button + model dropdown
   - Local: Show server URL input + "Test Connection" button + model dropdown
3. **Model selection:** After a successful connection test, load models and show
   a searchable dropdown. Store the selected model ID in the provider's
   settings.
4. **Connection status:** Show validation state (last tested, success/failure)
   from the cached settings.

**Key UX principle:** Test-then-use. Do not allow model selection until the
connection is verified. Do not allow AI operations until a model is selected.
This prevents confusing errors during actual use.

### AI Operations / Business Logic

Business logic consumes AI through the configuration builder, never through
provider services directly:

```
1. User triggers an AI operation (e.g., "organize this document")
2. Configuration builder reads current settings → { modelId, providerId, ... }
3. Config is passed to the AI execution layer (agent framework, direct API call)
4. Execution layer uses providerId to create the right SDK client
5. Result flows back to the UI
```

The business logic layer does not import any provider service classes. It only
knows about the config shape (`modelId`, `providerId`, `apiKey?`, `baseUrl?`).

### Server-Side Provider Resolution

If your architecture includes a server-side component (API server, agent
framework), you need a second factory for server-side SDK clients. This is
separate from the client-side factory because:

- Server-side uses AI SDK clients (Vercel AI SDK, LangChain, etc.) that return
  language model objects, not raw HTTP responses
- Server-side may support additional providers not available on the client
- Server-side does not need `testConnection` or `getAvailableModels`

The pattern is the same -- switch on `providerId` and create the right SDK
client -- but the return type is different (a language model object instead of a
service instance).

---

## Adding a New Provider

This is the key extensibility scenario. Adding a provider should require changes
in exactly these locations:

1. **Add the provider ID** to the provider ID enum
2. **Implement the provider class** extending the abstract base class (one file)
3. **Add a case** to the factory function's switch statement
4. **Add an entry** to the provider registry array
5. **Add settings** for the new provider in the settings type and defaults
6. **Add a config panel** component for the new provider's settings UI
7. **(If server-side)** Add a case to the server-side factory

No changes to business logic, no changes to the configuration builder, no
changes to the settings store actions. The type guards handle the new provider
automatically if it fits the cloud/local categorization.

**If the new provider does not fit cloud/local categories** (e.g., it requires
both an API key and a custom URL), either:

- Add a third category with its own settings type and type guard
- Or use the cloud settings type and add the URL as an extra field

Prefer adding a new category if the pattern will repeat. Use the extra-field
approach for one-off cases.

---

## Settings / Configuration

| Setting             | Type    | Default                   | Purpose                              |
| ------------------- | ------- | ------------------------- | ------------------------------------ |
| `selectedProvider`  | enum    | (app-specific)            | Which provider is currently active   |
| `apiKey`            | string  | `""`                      | API key for cloud providers          |
| `serverUrl`         | string  | Provider-specific default | Base URL for local providers         |
| `selectedModel`     | string  | `""`                      | Selected model ID per provider       |
| `isApiKeyValid`     | boolean | `false`                   | Cached key validation state          |
| `isConnectionValid` | boolean | `false`                   | Cached connection state (local)      |
| `lastValidatedAt`   | string  | `undefined`               | When credentials were last verified  |
| `autoLoadModels`    | boolean | `true`                    | Auto-load models on valid connection |
| `requestTimeout`    | number  | `30` (seconds)            | Timeout for AI requests              |

---

## Adapting to Different Tech Stacks

### Language & Runtime

- **TypeScript/JavaScript:** Abstract class with `abstract` methods. Factory is
  a plain function with a switch statement.
- **Python:** ABC (Abstract Base Class) with `@abstractmethod`. Factory is a
  function or classmethod.
- **Go:** Interface type. Factory is a function returning the interface. No base
  class -- use composition for shared utilities.
- **Swift:** Protocol with default implementations via protocol extensions.
  Factory is a static function.
- **Rust:** Trait with a factory function returning `Box<dyn ProviderTrait>`.

### State Management

- **Vue (Pinia):** Store with refs, computed properties, and actions. Reactive
  model lists. Use `storeToRefs` for template binding.
- **React (Zustand/Redux):** Store slice with selectors. Model lists in state.
  Use selectors for derived values (selected model name, etc.).
- **SwiftUI:** ObservableObject with @Published properties.
- **Server-side:** No store needed. Create provider instances per-request from
  request config.

### Desktop Security (Electron-style)

For desktop apps with a security boundary between UI and system:

- **Cloud providers** can make HTTP calls directly from the UI process (they go
  to external APIs over HTTPS).
- **Local providers** MUST make HTTP calls from the privileged process. The UI
  sends an IPC message ("get ollama models"), the main process makes the HTTP
  call to localhost, validates the response schema, and returns the result.
- **Why:** Local provider URLs point to localhost. Allowing the UI process to
  make arbitrary localhost requests is a security risk. The privileged process
  validates URLs and enforces allowlists.

### Agent Frameworks (Mastra, LangChain, Vercel AI SDK)

If using an agent framework, the provider factory pattern has a server-side
counterpart that creates framework-specific model objects:

```
function getAgentModel(runtimeConfig):
  switch (runtimeConfig.providerId):
    case 'openrouter':
      return createOpenRouterSDK(runtimeConfig.apiKey)(runtimeConfig.modelId)
    case 'ollama':
      return createOllamaSDK(runtimeConfig.baseUrl)(runtimeConfig.modelId)
    case 'lmstudio':
      return createOpenAICompatibleSDK(runtimeConfig.baseUrl)(runtimeConfig.modelId)
```

The client-side factory creates service objects for UI operations (test
connection, list models). The server-side factory creates language model objects
for agent execution. Both switch on the same provider ID enum.

---

## Gotchas & Important Notes

- **Separate client-side and server-side factories.** They return different
  types (service instances vs. language model objects) and have different
  concerns. Do not try to unify them into one factory.

- **Deep-merge settings on load.** When loading persisted settings, deep-merge
  with defaults. If you add a new setting field, existing users' persisted
  settings will not have it. Shallow merge loses nested defaults (e.g., adding a
  new field to `ollama` settings gets lost if you only spread the top level).

- **Clear model lists when switching providers.** If the user switches from
  OpenRouter to Ollama, clear the model list immediately. Showing stale
  OpenRouter models while Ollama models load is confusing.

- **Cache validation state, but re-validate on use.** Store `isApiKeyValid` so
  the UI shows the right state. But if an API call fails with 401, reset the
  cached state -- the key may have been revoked.

- **Local providers may need response sanitization.** Local models (especially
  reasoning models) can return markup like `<think>...</think>` blocks in their
  responses. Strip these before returning to the application.

- **Provider-specific error messages are high-value.** Generic "request failed"
  is useless. Map HTTP status codes to actionable messages: 401 = "Invalid API
  key, check your settings", 429 = "Rate limited, try again later", connection
  refused = "Is Ollama running?", etc.

- **Test connection before loading models.** For cloud providers, model listing
  may not require authentication (OpenRouter's model list is public). But
  testing the key first prevents a false sense of "everything works" when only
  model listing succeeds.

- **Convert reactive objects to plain objects before persisting.** If using a
  reactive state management system (Vue reactivity, MobX, etc.), serialize to a
  plain object before writing to persistent storage. Reactive wrappers can cause
  serialization issues or circular references.

- **Default models should be set after model list loads.** If no model is
  selected and models are loaded successfully, pick a sensible default (e.g., a
  well-known cheap model). Do not hardcode model IDs in business logic -- store
  them in settings with a fallback.

- **The provider ID enum is the source of truth.** Types, factory, registry,
  settings, and server-side factory all reference the same enum. If you add a
  provider to the enum but forget the factory case, the `default: throw` catches
  it immediately.
