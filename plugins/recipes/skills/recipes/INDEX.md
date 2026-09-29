# Recipe Index

Implementation guides for specific tech-stack patterns. Each entry below points
at `library/<name>/RECIPE.md` — read that file for the full guide.

## Authentication & API

- **`elysia-betterauth-api`** — Bun + Elysia + BetterAuth + Drizzle + PostgreSQL
  API server with session-based authentication.
- **`elysia-betterauth-oauth`** — Add OAuth 2.1 with PKCE to a BetterAuth +
  Elysia API for native desktop / mobile clients.
- **`electron-betterauth`** — BetterAuth in an Electron app with OS-level token
  encryption (safeStorage), automatic refresh, and strict main↔renderer
  boundaries.
- **`nuxt-betterauth-admin`** — Nuxt 4 admin dashboard against a BetterAuth +
  Elysia backend, with cookie auth, RBAC, and user management.

## Sync & Real-Time

- **`powersync-local-first-sync`** — Bidirectional sync between local SQLite and
  PostgreSQL via PowerSync + Drizzle + BetterAuth JWT.
- **`live-websocket-sync`** — Real-time unidirectional state sync from a host
  app to mobile/web clients over WebSocket, with debounced updates, new-client
  detection, and reconnect.

## Desktop & Mobile

- **`electron-vue-ipc`** — Electron + Vue 3 + Pinia + TypeScript with typed IPC,
  modular handlers, and Pinia stores as the IPC integration layer.
- **`expo-voice-to-text`** — Voice-to-text pipeline in an Expo React Native app
  — recording → transcription → document creation, with swappable STT providers.
- **`qr-code-local-pairing`** — QR-code scanning on mobile to connect to a local
  service on the same network (replaces manual IP entry).
- **`dev-prod-build-identity`** — Side-by-side dev and prod builds with distinct
  icons, app names, bundle IDs, and data isolation.

## Editor & Document

- **`auto-save-dual-debounce`** — Document auto-save with dual-layer debouncing
  — responsive undo/redo plus batched DB writes.
- **`document-versioning`** — Linear document versioning with active version
  tracking, manual milestones, configurable limits, and optional AI integration.
- **`soft-delete-restore`** — Soft delete with restore via a nullable
  `deletedAt` column.

## AI & MCP

- **`ai-provider-factory`** — Multi-provider AI abstraction layer with a factory
  function and pluggable backends (cloud + local).
- **`openrouter-model-categories`** — Category-based AI model management with
  admin UI for browsing OpenRouter models and assigning semantic categories.
- **`api-mcp-server`** — Cloud-hosted MCP server on a Bun/Elysia API with
  multi-tenant isolation, agent key auth, and DB-backed sessions.
- **`agent-feedback-reporting`** — Agent feedback reporting system — tool call
  lets agents report difficulties, with admin UI for review.

## Asset Management

- **`media-library`** — Full media library with admin UI for audio / image
  uploads, S3-compatible storage, AI-assisted metadata, and maintenance tools.

## Agent Surfaces

- **`agent-surface-bun`** — Bun + TypeScript scaffold for agent-driven browser
  surfaces in two shapes: **one-shot** (open → user works it → submit) and
  **standing** (a persistent daemon holds canonical state, driven by a stateless
  thin CLI over HTTP/SSE, with a WebSocket browser). Covers the daemon-detach
  substrate (`node:child_process`, not `Bun.spawn`), `/events` cursor/actor
  frame design, anti-flood stdio discipline, and a vanilla→Alpine→React
  surface-tech ladder. Canonical worked examples live in the `spellbook` repo.

## Tooling & Build

- **`project-cli-toolkit`** — Companion guide for the `create-project-cli`
  installer; explains the dual-audience CLI (TTY-text for humans, JSON envelopes
  for agents) and how to extend a scaffolded CLI.
- **`zed-biome-husky-quality-gates`** — Biome as the single format/lint
  authority with Zed editor integration and Husky pre-commit enforcement.

---

**Adding a recipe?** Use the `recipes:create-recipe` skill — it scaffolds a new
entry under `library/` and prompts you to update this index.
