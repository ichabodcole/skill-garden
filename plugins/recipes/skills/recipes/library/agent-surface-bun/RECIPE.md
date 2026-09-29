# Agent Surface (Bun) Recipe

## Purpose

Build a browser-based UI that an AI agent drives — a "surface" the agent opens
for the user, exchanges state with, and (sometimes) tears down when the
interaction is over. Examples: a doc-review page with embedded questions
(`digestify`), a task board the agent posts work into and the user drags around
(`bounty`), a side-by-side comparison view, a configurator, a live editor.

The common shape: the agent runs a local process that serves a browser UI on
`127.0.0.1`; the agent and the browser exchange messages _through_ that process
(the agent never talks to the browser directly); the agent collects a result.
There are **two shapes**, and this recipe covers both:

- **One-shot** — the agent spawns the surface, passes content up-front, the user
  reads/responds, a single submit ends it, and the surface prints a JSON result
  on stdout and exits. Asynchronous: open → user works it → submit. (digestify's
  model.)
- **Standing** — a long-lived **daemon** holds canonical state; the agent drives
  it across a whole session through a stateless thin `cli.ts` (one HTTP
  round-trip per verb) and tails a live event stream. The surface stays open and
  the human and agent pass state back and forth in real time. (imago / grapevine
  / bounty.)

This recipe is the implementation-agnostic abstraction. The canonical worked
implementations live in the standalone `spellbook` repo; read those when you
want a full example (see
[Reference Implementations](#reference-implementations)).

> **Weighting:** the **standing** shape gets the most depth here — it's where
> agent-driven surfaces are trending (dynamic, real-time collaboration between
> an agent and a human). The **one-shot** shape is still the right call when a
> standing surface would be overkill; it's documented but kept lean.

## When to Use

- You need the user to **see something rendered** (markdown, a custom UI, a
  diagram) rather than read it in chat.
- You want the user to **interact with state** the agent is shaping — pick from
  options, drag, type into specific fields, leave inline comments.
- A single round trip isn't enough — or the interaction is short but the page
  needs to be more than a text reply.
- You want the work to feel like a tiny dedicated mini-app, not a wall of chat.

Not the right fit for: lengthy iterative chat, anything where the user is the
primary author of the document (this is for agent-driven surfaces).

### Which shape when

| Choose **one-shot** when…                              | Choose **standing** when…                                            |
| ------------------------------------------------------ | -------------------------------------------------------------------- |
| The interaction is a single async round trip           | The agent and user collaborate back-and-forth across a whole session |
| The agent hands off content, then waits for one submit | State evolves continuously and both sides react to each other        |
| No live updates needed once the page is open           | The agent needs to push updates _and_ react to user actions live     |
| The surface can be ephemeral (no durable state)        | Canonical state must persist and survive reconnects / relaunch       |
| One agent, one user                                    | Multiple agents and/or a user share one surface (per-owner scoping)  |

Rule of thumb: start one-shot; reach for standing the moment you find yourself
wanting to _re-open the same surface_ to push an update or read what changed.

## Technology Stack

| Layer              | Technology                                                                                   |
| ------------------ | -------------------------------------------------------------------------------------------- |
| Runtime            | [Bun](https://bun.sh) 1.3+                                                                   |
| Language           | TypeScript (Bun runs `.ts` natively, no transpile step)                                      |
| HTTP/WS server     | `Bun.serve` (built-in) — runs _inside_ the surface/daemon                                    |
| Daemon process     | Launched via `node:child_process` `spawn` (`detached: true` + `unref()`) — **standing** only |
| Agent ↔ daemon    | HTTP: `POST /cmd`, `GET /state`, `GET /events` (SSE) — **standing**                          |
| Agent ↔ surface   | `Bun.spawn` + JSON-lines stdio — **one-shot**                                                |
| Browser ↔ surface | WebSocket (standing, full-state broadcast) or fetch/POST (one-shot)                          |
| Browser build      | None required (CDN libs); optional Bun HTML-import bundler for the React rung                |
| Test runner        | `bun test` (built-in)                                                                        |

**Why Bun, not Node / Deno / Python:**

- **Single-runtime install for the user.** Anyone running an agent surface needs
  `bun` on PATH — and that's the entire dependency. No `npm install`, no
  `pip install`, no per-skill node_modules.
- **Built-in `Bun.serve` is great** — no Express / Fastify / Hono required.
  HTTP + WebSocket + SSE + path-traversal-safe asset serving in ~30 lines.
- **Native TS** — protocol message types live in the same file as the handler;
  no transpile step.
- **The runtime fits both shapes.** One-shot: `Bun.spawn` + JSON-lines stdio is
  the whole agent contract. Standing: the agent drives a long-lived daemon over
  HTTP via a thin `cli.ts`, and the daemon is launched **detached** so it
  outlives the CLI — see
  [the substrate gotcha](#standing-daemons-launch-with-nodechild_process-not-bunspawn).
- Python's stdlib `http.server` works fine for the one-shot case but lacks
  built-in WebSockets, requiring a third-party install — defeats the zero-dep
  goal.

## Architecture

The agent never talks to the browser directly — a local process (the surface, or
the daemon) is always the proxy. The two shapes differ in how long that process
lives and how the agent talks to it.

### One-shot variant

```
agent ──spawn──► surface ──http──► browser
                                  ◄──submit── (POST /submit)
agent ◄──stdout (JSON)── surface  (exits)
```

- Agent passes the full content up-front (stdin or `--file`).
- Surface serves a single page; the browser does its thing.
- One POST `/submit` ends the session.
- Surface prints a JSON result and exits.

Exit codes:

| Code | Meaning                                       |
| ---- | --------------------------------------------- |
| 0    | User submitted                                |
| 2    | Bad input (no content, parse error, bad args) |
| 124  | Idle timeout                                  |
| 130  | User cancelled (closed tab after interacting) |

### Standing variant (daemon + thin-CLI)

A persistent **daemon** owns canonical state. The agent never holds a long-lived
process of its own — it runs a stateless `cli.ts` that does **one HTTP
round-trip per verb**, and tails a live event stream to learn what changed.

```
                 HTTP, one round-trip per verb
                 POST /cmd  ·  GET /state  ·  GET /events (SSE)
   ┌──────────┐  ───────────────────────────────────────────►  ┌───────────────┐
   │  AGENT   │                                                  │    DAEMON     │
   │ cli.ts   │  ◄───────────────────────────────────────────   │  (Bun.serve)  │
   │(stateless)│        SSE event stream (GET /events?since=)     │  canonical    │
   └──────────┘                                                  │    state      │
                                                                 └──────┬────────┘
                                                                        │ WebSocket
                                                                        │ (full-state broadcast)
                                                                        ▼
                                                                 ┌───────────────┐
                                                                 │    BROWSER    │
                                                                 └───────────────┘

   daemon started once, detached: node:child_process spawn(detached:true) + unref()
```

The contract has four surfaces:

- **Write — `POST /cmd` with a `--stdin` body.** Each verb is one POST. Pass
  natural-language text via **stdin**, never inlined into a shell-parsed
  argument string — that avoids a real apostrophe/metacharacter quoting bug
  ("don't" or `; rm` in a title shouldn't break the command).
- **Read-back — `GET /state[?lean=1]`.** After a write, the agent reads state to
  confirm the command applied and to discover **server-assigned ids**. The agent
  is no longer write-only; `?lean=1` returns a trimmed projection for cheap
  polling.
- **Live push — `GET /events?since=<id>` (SSE).** A monotonic-id event stream
  the agent tails through its watcher/Monitor primitive. `?since=<id>` resumes
  from a cursor so a reconnecting agent **loses nothing**. A curated
  **wake-set** decides which event types should wake the agent versus which it
  just reads via `/state` — so the agent isn't woken by its own noise.
- **Browser ↔ daemon stays WebSocket.** The daemon broadcasts full state to
  browsers over WS; late-joining browsers get a synthetic full-state message on
  connect. **Transport is asymmetric by audience:** the agent talks HTTP, the
  human's browser talks WS, against the same daemon.

**Persistence lives in the daemon.** Canonical state is snapshotted (debounced)
to disk; `open --restore` merges the snapshot over current defaults so the state
shape can evolve forward-compatibly. Durable state is a first-class part of this
shape, not an out-of-scope concern.

> stdio JSON-lines (the agent streaming line-protocol over a child's
> stdin/stdout) is the **prior generation** of the standing shape. It's still
> fine for the simplest streaming case, but it can't express a surface that
> outlives the agent turn, persists state, or serves multiple reconnecting
> clients — for that, use the daemon + thin-CLI substrate above.

## Build a New Surface — Step by Step

### One-shot

1. **Copy the one-shot shape** into your skill folder as `scripts/<name>.ts`.
2. **Edit the protocol types** — what the agent passes in (markdown? config
   object?) and what the submit response looks like. Keep them at the top of the
   file so the contract reads first.
3. **Write your `template.html`** — self-contained, no build step. Use
   `__TITLE__` / `__PAYLOAD__` placeholder tokens the script substitutes before
   serving. CDN libraries (Marked, DOMPurify, Lucide) go inline as `<link>` /
   `<script>`.
4. **Wire up `Bun.serve`:** `GET /`, `GET /assets/*` (with a path-traversal
   guard), `POST /submit`, `POST /cancel`, `POST /heartbeat`.
5. **Connect agent stdio:** read once at startup (with a ~100ms timeout on stdin
   so a dead/empty stdin doesn't hang forever).
6. **Write the SKILL.md** — trigger conditions, invocation, response format,
   exit codes, and a Prerequisite section noting Bun on PATH.
7. **Add a `bun test` file** — pure-function coverage of your parser, plus a few
   subprocess integration tests for submit / cancel / timeout.

### Standing

1. **Copy the standing shape** — a `daemon.ts` (the long-lived `Bun.serve`
   process that owns state) and a thin `cli.ts` (one HTTP round-trip per verb).
2. **Define three shapes up front:** the **command** verbs (`open`, your domain
   mutations, `close`), the **state** projection (`GET /state` and its `?lean=1`
   form), and the **event-frame** shape for `GET /events` — kept _separate_ from
   the WS/browser message shape (see the `/events` gotchas).
3. **Launch the daemon detached.** The first `cli.ts open` starts the daemon via
   `node:child_process` `spawn` with `detached: true` + `unref()` so it survives
   the CLI exit; every later verb just reconnects over HTTP. Track the port in a
   small lockfile/`localStorage`-of-the-filesystem so the CLI finds the running
   daemon.
4. **Wire `Bun.serve` in the daemon:** `POST /cmd` (reads a `--stdin` body),
   `GET /state[?lean=1]`, `GET /events?since=<id>` (SSE), a `/ws` upgrade for
   the browser, and `GET /assets/*` with a path-traversal guard.
5. **Make every mutation emit an event** — including agent `/cmd` writes — each
   stamped with an actor (`by: "user" | "agent" | "system"`) and the monotonic
   envelope `id`. Broadcast full state to WS browsers on each change.
6. **Tail with discipline.** The agent wraps `GET /events` in its
   watcher/Monitor primitive; payloads go to **stdout**, liveness/echo to
   **stderr**, and the agent suppresses its own echoes (see the anti-flood
   pattern).
7. **Persist.** Debounced snapshot to disk; `open --restore` merges it over
   defaults.
8. **Write the SKILL.md + a `bun test` file** as for one-shot, covering the
   state-merge logic and a subprocess test that opens a daemon, sends a `/cmd`,
   and asserts `/state` + an `/events` frame.

## Gotchas (read these once)

These bit while building the reference surfaces; capturing them so you don't
have to re-discover.

### Standing daemons: launch with `node:child_process`, not `Bun.spawn`

**The single most load-bearing correction in this recipe.** A standing daemon
must outlive the thin `cli.ts` that started it. `Bun.spawn` cannot fully detach
a child that survives the spawning process — so it structurally _cannot_ express
a standing surface. Launch the daemon with Node's `child_process.spawn` using
`detached: true` + `child.unref()`, with stdio redirected to `ignore` or a log
fd:

```ts
import { spawn } from "node:child_process";

const daemon = spawn("bun", [daemonScript, "--port", String(port)], {
  detached: true,
  stdio: "ignore", // or a log file fd
});
daemon.unref(); // the cli.ts parent can now exit without waiting
```

`Bun.serve` still runs _inside_ the daemon and `bun` is still the runtime — this
correction is **only** about how the daemon process is started.

### `/events` frame: don't let a payload `id` clobber the cursor

The SSE envelope's `id` _is_ the resume cursor — the value a reconnecting agent
passes back as `?since=`. If you build frames as `{ id: ++seq, ...msg }` and
`msg` already carries its own `id` (e.g. a task id), the spread overwrites the
cursor and **resume silently breaks**.

```ts
// ✗ inner id clobbers the monotonic cursor
log.push({ id: ++seq, ...msg }); // msg.id wins → cursor corrupted

// ✓ envelope id IS the cursor; rename the inner identifier for agent frames
log.push({ id: ++seq, ...msg, taskId: msg.id });
```

Keep the agent-facing SSE frame shape **separate** from the WS/browser message
shape so the two meanings of `id` never collide.

### `/events` frame: every mutation emits, tagged with an actor

The event log must record **every** state mutation — including the agent's own
`/cmd` writes, not just browser-origin actions. If agent writes don't emit, a
second agent tailing a scoped / `--owner` stream never sees them, and
agent-to-agent coordination (e.g. a lead assigning a task via the CLI) is
invisible — which defeats per-owner subscriptions entirely.

```ts
type Actor = "user" | "agent" | "system";
emit({ id: ++seq, type, ...payload, by }); // by: Actor
```

With an actor tag, a tail can suppress its own echoes and scope by owner.
Self-echo suppression is therefore **load-bearing, not optional** — without it
an agent that writes via `/cmd` wakes itself on its own event in a loop.

### `Bun.spawn({ stdin: "pipe" })` returns a `FileSink`, not a `WritableStream`

(One-shot path, where the agent spawns the surface via `Bun.spawn`.) Use
`proc.stdin.write(bytes)` directly. `proc.stdin.getWriter()` throws
`TypeError: proc.stdin.getWriter is not a function`. End the stream with
`proc.stdin.end()`.

```ts
const proc = Bun.spawn({ cmd: [...], stdin: "pipe", stdout: "pipe" });
const enc = new TextEncoder();
proc.stdin.write(enc.encode(JSON.stringify({ type: "init", ... }) + "\n"));
proc.stdin.end(); // close on EOF
```

### `server.stop()` can stall on WebSocket handshake even with `true`

In `Bun.serve`, both `server.stop()` (graceful) and `server.stop(true)` (force)
can hang for several seconds when there's an outgoing WS close in flight. Race
it against a short timer:

```ts
await Promise.race([server.stop(true), new Promise((r) => setTimeout(r, 200))]);
```

Then let `process.exit(code)` finish the job.

### Browser races against teardown when submit triggers a new asset fetch

After `POST /submit` returns, your client-side handler may render a "done" state
that loads new assets (e.g. a celebratory mascot from `/assets/...`). If you
call `server.stop()` immediately, the asset request lands on a dead server and
the done-screen renders broken. A short grace period — only on the submit path —
fixes it:

```ts
const { code } = await done;
if (code === 0) await new Promise((r) => setTimeout(r, 700));
await Promise.race([server.stop(true), new Promise((r) => setTimeout(r, 200))]);
```

### `process.stdout.write` can throw `EPIPE` if the agent died first

Wrap your write helper so a dead parent can't crash you during cleanup:

```ts
function emitToAgent(msg: ServerToAgentMsg): void {
  try {
    process.stdout.write(JSON.stringify(msg) + "\n");
  } catch (e: any) {
    if (e?.code !== "EPIPE") throw e;
  }
}
```

### `bun test` requires `.test.` or `.spec.` in the filename

Bun won't pick up `test_review.ts` — rename to `review.test.ts`.

## Patterns Worth Reusing

### Anti-flood: payload on stdout, liveness on stderr

When the agent tails `GET /events` through its watcher/Monitor primitive, keep
the signal clean: **real payloads go to stdout; liveness/keepalive and echo go
to stderr — never fold them together (`2>&1`)**. The watcher turns stdout lines
into wake-ups, so a keepalive on stdout floods the agent with noise that buries
real messages. Pair this with self-echo suppression and scoped/filtered reads so
the agent only wakes on events it actually cares about.

This is the same lesson as grapevine V1.6.8 (issue #140): a liveness tick folded
onto the event stream became a notification flood. `grapevine` is the cleanest
reference for the stdout/stderr split and the SSE-tail-with-resume shape.

### Surface-tech ladder: vanilla → Alpine → React

Three rungs — climb only when the surface's complexity earns it:

1. **Vanilla inline JS + DOM** — zero build, fastest to ship. Right for most
   one-shot surfaces and simple standing boards.
2. **Alpine.js over CDN** — declarative reactivity with **no build step**
   (`<script src>` the CDN bundle). The sweet spot when vanilla DOM wiring gets
   tedious but you still want zero tooling.
3. **React via Bun's HTML-import bundler** — `import index from "./index.html"`
   with `Bun.serve`, a `bunfig.toml` for Tailwind, and HMR in dev. Reach for
   this when the standing surface has enough interactive state to justify a
   component model; the long-lived daemon makes a build step viable (you're not
   re-bundling per agent invocation).

Don't reproduce Bun's bundler docs here — see
[Bun's HTML & full-stack docs](https://bun.sh/docs/bundler/html) for the setup,
and the **imago** surface for a worked React-on-a-standing-daemon example. (The
principle: this recipe earns its space on hard-won patterns; for anything
already documented elsewhere, link to it rather than copy it.)

### Session id with embedded port (one-shot)

`digestify-<8-hex>-p<port>` lets a relaunch reuse the same port. Same origin →
same browser `localStorage` namespace → in-progress drafts survive. The script
parses the port out of `--id` and tries to bind it; falls through to a random
port if taken. (The standing shape solves the same "find my surface again"
problem with a daemon lockfile instead.)

### Sliding-window idle timeout

`--timeout` is the **idle** threshold, not absolute. Heartbeats (a POST, a WS
message, or an inbound `/cmd`) reset the clock. A user actively working stays
past the original window; an abandoned page exits at the configured idle
interval. Simpler than tracking absolute deadlines and matches user intuition.

### Path-traversal guard for assets

```ts
if (assetName.includes("..") || assetName.startsWith("/")) {
  return new Response('{"error":"not found"}', { status: 404 });
}
```

`Bun.file(join(assetsDir, assetName)).exists()` then handles the
not-found-but-real-path case.

### JSON payload `</` escaping

If you inline a JSON payload into an HTML `<script>` tag, escape `</` so content
like `"</script>"` in a title can't close the surrounding tag:

```ts
const payloadJson = JSON.stringify(payload).replace(/<\//g, "<\\/");
```

The browser still parses it as valid JSON.

## Reference Implementations

The canonical worked examples live in the standalone `spellbook` repo,
referenced here by **name and role only** — `spellbook` is their single source
of truth and its internal layout evolves, so this recipe doesn't pin file paths.

- **`imago`** — the richest **standing** example: a canonical-state daemon with
  snapshot/restore, the `POST /cmd` + `GET /state` + `GET /events` contract, and
  a React surface via Bun's HTML-import bundler. Read this first for the
  standing shape.
- **`grapevine`** — the cleanest **agent CLI**: `--stdin` writes, strict
  stdout/stderr discipline, and an SSE tail with resume-from-cursor. The
  reference for the agent-facing contract and the anti-flood discipline.
- **`bounty`** — a **standing task board** (drag-and-drop, multi-agent
  participation): the worked example of a board on the daemon + thin-CLI
  substrate.
- **`digestify`** — the **one-shot** reference: markdown with `:::question`
  fences, themed UI, inline comments, session recovery via `localStorage`; plus
  a `bun test` suite (pure-function + subprocess integration tests, with helpers
  like `spawnAndWaitForReady` / `postSubmit`) worth copying.

> These surfaces were extracted from this repo's `toolbox` plugin to `spellbook`
> as their single source of truth. As the pattern keeps evolving there, fold the
> learnings back into this recipe via a PR or issue.

## What This Recipe Doesn't Cover

- **Multi-user / remote surfaces.** Everything binds to `127.0.0.1`. A surface
  the user can hit from another device is a different problem (tunneling, auth,
  TLS).
- **Cross-session persistence for one-shot surfaces.** A one-shot surface is
  ephemeral — its only client-side memory is `localStorage`. (The **standing**
  shape is the opposite: its daemon owns canonical state and persists it via
  debounced snapshot + `open --restore`. Durable state is in-scope _there_, just
  not for one-shot.)
- **Heavy UI frameworks without a plan.** Vanilla DOM and Alpine-over-CDN need
  no build. React is supported via Bun's HTML-import bundler (see the ladder) —
  made viable because a standing daemon amortizes the build — but don't reach
  for it before the surface's complexity earns it.
