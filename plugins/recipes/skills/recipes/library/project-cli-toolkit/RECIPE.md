# Project CLI Toolkit Recipe

## Purpose

A project-specific CLI unifies your scripts (DB migrations, dev dumps, auth
bootstrap, code generators) behind a single entry point that both humans and AI
agents can drive. Humans get pretty text; agents get structured JSON — from the
same binary, decided automatically based on whether stdout is a TTY.

This skill is the **companion doc** for the
[`create-project-cli`](https://github.com/ichabodcole/seed-project-cli)
installer. The installer ships the working scaffold. This skill explains **why
it's shaped the way it is** and **how to extend it by hand**.

## Two Paths

### "Just make me a CLI" — run the installer

```bash
bunx github:ichabodcole/seed-project-cli <cli_name>
# or: npx github:ichabodcole/seed-project-cli <cli_name>
```

> **Install path note.** The installer is not yet on npm — the
> `bunx create-project-cli` short form is planned but does **not** work today;
> it'll return "package not found." Always use the `github:` spec until this
> skill is updated to say otherwise.

In an interactive shell the installer prompts for package manager, scope labels,
and whether to include the optional layers (API client, auth bootstrap, identity
banner). After generation:

```bash
<pm> run <cli_name>               # grouped help
<pm> run <cli_name> info show     # smoke-test the scaffold
<pm> run <cli_name> help --json   # full machine-readable manifest
```

Done. You have a working dual-audience CLI. If you never need to go deeper, you
can stop reading here.

### Driving the installer from an agent or CI (non-interactive)

The installer auto-switches to non-interactive mode when **either** `--yes` is
passed **or** stdin is not a TTY — never pipe into a `@clack/prompts` TUI.
Resolution per setting: explicit flag → interactive prompt (skipped in
non-interactive mode) → default.

| Flag                         | Effect                                                      |
| ---------------------------- | ----------------------------------------------------------- |
| `-y`, `--yes`                | Accept defaults for unasked items (non-interactive)         |
| `--pm <bun\|pnpm\|npm>`      | Package manager                                             |
| `--project-package-name <s>` | Host `package.json` name for root discovery                 |
| `--api` / `--no-api`         | Include API client layer                                    |
| `--auth` / `--no-auth`       | Include auth bootstrap (**implies `--api`** when unopposed) |
| `--banner` / `--no-banner`   | Include ASCII identity banner                               |
| `--api-env-path <path>`      | Path to API `.env` (default: `apps/api/.env`)               |
| `--api-entry-path <path>`    | Path to API entry (default: `apps/api/src/index.ts`)        |
| `--install` / `--no-install` | Install `citty` (+ `tsx`) after scaffold                    |
| `-h`, `--help`               | Print usage and exit                                        |

Recommended agent invocation:

```bash
# Fully specified — zero prompts
bunx github:ichabodcole/seed-project-cli myproj \
  --yes --pm bun --api --auth --no-banner --install

# Minimal — defaults for everything except the API toggle
bunx github:ichabodcole/seed-project-cli myproj --yes --api
```

**Exit-code contract** in non-interactive mode: missing `<cli-name>` exits with
code **2** plus a usage line (not 1). Treat `exit 2` as "bad invocation, fix
flags and retry"; reserve retry-after-diagnose for other non-zero codes.

### "I need to understand or extend one" — read on

Continue past this section when you're:

- adding app-scope commands that need pagination, short-ID resolution, or
  progress reporting,
- growing beyond the flat `commands/` layout (~30+ files),
- renaming scope labels (e.g. `workspace`/`app` → `local`/`remote`),
- adapting the auth layer to something other than BetterAuth,
- writing tests for commands,
- or debugging something that the installer's generated comments don't cover.

## Mental Model

```
  ┌───────────────────────────────────────────────────────────────┐
  │                         myproj (cli.ts)                       │
  │   • declares top-level groups + root flags                    │
  │   • intercepts `help --json` → manifest                       │
  │   • intercepts bare / `help` → grouped help renderer          │
  │   • otherwise delegates to citty's runMain                    │
  └────────────────────────────────┬──────────────────────────────┘
                                   │
         ┌─────────────────────────┼──────────────────────────┐
   ┌─────▼───────┐           ┌─────▼──────┐            ┌──────▼──────┐
   │  info       │           │  api-proxy │            │  ...group N │
   │  (workspace)│           │  (app)     │            │             │
   └─────┬───────┘           └─────┬──────┘            └─────────────┘
         │                         │
   ┌─────▼────────────┐      ┌─────▼────────────┐
   │  info-show.ts     │     │  api-user-list.ts │
   │  info-env.ts      │     │  api-user-get.ts  │
   └───────────────────┘     └───────────────────┘
                                   │
                             ┌─────▼───────────────────┐
                             │  api-client.ts          │
                             │  apiFetch / error map   │
                             └─────────────────────────┘

  Every command:   resolveFormat(--format) → try/catch → emit/emitError
  Every emit:      text mode → renderText() ;   json mode → envelope
```

### Core concepts

**Dual-audience output.** Every command writes through an `emit()` helper that
takes a `renderText` closure. In text mode it calls the closure; in JSON mode it
wraps the raw data in a `{ ok, data, meta }` envelope. Format resolution is:
explicit `--format` flag wins, else `process.stdout.isTTY` is used to
auto-detect. Agents don't need to pass a flag — their lack of a TTY _is_ the
signal.

**Machine-readable manifest.** `<cli_name> help --json` walks the citty tree and
emits a JSON description of every group, command, flag, default, alias, and
scope. Agents call it once per session to discover the surface, instead of
scraping ANSI-colored help text. The manifest walker is the single source of
truth; the human help renderer is built on top of it.

**Scope tagging.** Every top-level group declares `scope: "workspace" | "app"`
on its meta — `workspace` = local/filesystem operations, `app` = requires the
API + auth. Scope is inherited by subcommands via the manifest walker. The human
help renderer uses it to print two clearly-labeled sections; agents use it (via
the manifest) to decide whether to spin up the API before running a command.

**Stable envelope shape.**

- Success: `{ ok: true, data, meta: { command, durationMs } }`
- Error: `{ ok: false, error: string, meta: { command } }`

`meta.command` is the space-joined path (e.g. `"library list"`) so log
aggregation stays grouped.

### Trade-offs accepted

- **Citty, not Commander / oclif / clipanion** — its command tree is simple
  enough to introspect for the manifest without plugins. Higher-level frameworks
  hide the structure behind lifecycle hooks that make walking the tree brittle.
- **One binary, two output modes** — no separate agent-only binary. Keeps
  discovery centralized: one manifest, one set of docs, one place to add
  commands.
- **Hand-rolled ~20-line ANSI helpers** instead of a colors library. The
  `NO_COLOR` env var plus an `isTTY` check cover the real cases; zero dependency
  surface.

## Naming Convention in This Recipe

Throughout the code and prose the following tokens are placeholders — substitute
your project's identifier when extending:

| Placeholder | Substitute with                           | Example          |
| ----------- | ----------------------------------------- | ---------------- |
| `myproj`    | lowercase CLI binary / package / dir name | `loom`, `acme`   |
| `MyProj`    | PascalCase prefix for TypeScript types    | `Loom`, `Acme`   |
| `MYPROJ_`   | SCREAMING_SNAKE env var prefix            | `LOOM_`, `ACME_` |

The installer derives all three from your chosen CLI name; when editing by hand
keep them consistent.

## Extending the Scaffold

### Adding commands

One subcommand per file, named `<group>-<sub>.ts`, imported by the group file.
Group files never contain command logic — only imports + `subCommands` wiring.

**The shape every `run(ctx)` follows:**

```typescript
import { emit, emitError, resolveFormat } from "../agent-layer.ts";
// app-scope commands also:
// import { apiFetch, mapApiError } from "../api-client.ts";

async run(ctx) {
  const format = resolveFormat(ctx.args.format);
  try {
    const data: MyData = /* ... */;
    emit<MyData>({
      format,
      command: "group sub",              // space-joined path
      data,
      renderText: (d) => `...`,           // pure function of data
    });
  } catch (err) {
    emitError({
      format,
      command: "group sub",
      error: err instanceof Error ? err.message : "unknown error",
    });
    process.exit(1);
  }
}
```

**Non-obvious rules:**

- **Always declare `args.format` locally.** Citty doesn't inherit root flags.
  `--format json` on a subcommand is silently ignored unless the subcommand
  declares it.
- **`renderText` is a pure function of `data`.** Both modes consume the _same_
  object, so a broken text renderer cannot silently corrupt JSON mode.
- **`command` in `emit` is the space-joined path** (`"library list"`), not the
  leaf name. It's the grouping key for agent telemetry.

### App-scope command patterns

These patterns appear in commands that hit the API and return lists or mutable
records. The installer doesn't ship them — they're project-specific.

**Short-ID prefix resolution.** Agents that read a list and then act on a
specific row shouldn't juggle full UUIDs through multi-step flows. Client
helper:

```typescript
export async function resolveIdPrefix(
  prefix: string,
  listPath: string
): Promise<string> {
  if (prefix.length >= 36) return prefix;
  const result = await apiFetch<{ items: Array<{ id: string }> }>(listPath, {
    query: { idPrefix: prefix, limit: 2 },
  });
  if (result.items.length === 0)
    throw new Error(`no match for prefix "${prefix}"`);
  if (result.items.length > 1)
    throw new Error(`prefix "${prefix}" is ambiguous`);
  return result.items[0]!.id;
}
```

**This is a paired pattern** — the API must accept an `idPrefix` query filter
(`WHERE id::text LIKE $1 || '%'`, or equivalent). Ship both halves or neither;
the client alone will produce confusing 400/404s on first run. Consider
extracting this pair as its own recipe if you use it in multiple projects.

**Pagination conventions.** For list endpoints that can return many rows:

- Accept `--limit` (default 20) and `--cursor` (opaque string) on the
  subcommand.
- Put `nextCursor` into the envelope's `data` (not `meta`) — it's useful output,
  not metadata.
- Text renderer prints only the first page and a "… N more (use `--cursor` to
  continue)" footer. JSON mode returns the whole page as-is.

**Long-running commands.** For commands that take more than a few seconds:

- In text mode, emit progress to stderr (never stdout — it mixes with the final
  output) and use CR (`\r`) to rewrite the same line.
- In JSON mode, stay silent until the end. Agents parsing NDJSON can't
  interleave progress with the final envelope.
- If the command is resumable, accept a `--resume-token` flag and include
  `resumeToken` in the error envelope when it fails mid-run.

### Growing past the flat commands/ layout

The installer emits `commands/<group>-<sub>.ts`. That's fine up to ~30 files.
Past that, move to subdirectories:

```
commands/
  api-user/
    list.ts
    get.ts
    create.ts
    delete.ts
    index.ts           — defines the group, imports + wires siblings
  log/
    list.ts
    level.ts
    index.ts
```

Migration is mechanical:

1. Create `commands/<group>/` directory.
2. Move `commands/<group>-<sub>.ts` → `commands/<group>/<sub>.ts`.
3. Move `commands/<group>.ts` → `commands/<group>/index.ts`, update relative
   imports.
4. Update `cli.ts`: `import { xCommand } from "./commands/x/index.ts"` (or just
   `./commands/x`).
5. `command` strings in each subcommand's `emit` stay the same
   (`"api-user list"`) — the file path and the user-facing command path are
   decoupled, which is the point.

### Renaming scope labels

The installer ships `"workspace" | "app"`. If those labels don't fit your
project, rename them in two places:

1. **`define.ts`** — the `MyProjCommandScope` type union.
2. **`help-renderer.ts`** — the `SCOPE_ORDER` constant (or equivalent iteration
   over scope values) and the label map.

The manifest walker doesn't care about specific label strings; it just threads
whatever `scope` value is on the meta through `inheritedScope`. Existing
commands continue working as long as their `scope` values match the new type
union.

**Don't:** rename scopes asymmetrically across commands (some still using old
labels). The type checker won't catch it because citty's meta accepts freeform
strings.

### Adapting the auth layer

The generated `auth` group assumes a BetterAuth-compatible sign-in endpoint:

- `POST /api/auth/sign-in/email` with `{ email, password }`
- returns `{ token, user: { id, email } }`

For other providers, edit `commands/auth-login.ts` in two places:

1. **Request shape** — the body your provider expects (OAuth code + state, magic
   link token, API key exchange, etc.).
2. **Response mapping** — pull the bearer token and whatever "you are logged in
   as X" identity info the provider returns.

Everything else (writing `MYPROJ_API_BEARER` into `.env`, touch-reloading
`API_ENTRY`, the `auth status` / `auth whoami` commands) stays the same. The
`apiFetch` layer is auth-provider-agnostic — it only cares that there's a bearer
token in `MYPROJ_API_BEARER`.

**Caveats for common providers:**

- **OAuth 2.1 with PKCE** (desktop/mobile clients) — the CLI is a poor fit for
  the PKCE dance; prefer a device-code flow or exchange a pre-issued refresh
  token.
- **Session cookies** instead of bearer tokens — the whole `apiFetch` design
  breaks down; you'd need to persist a cookie jar and send it on every request.
  At that point, consider a different client pattern.

### Test scaffolding

The installer deliberately doesn't scaffold tests — project conventions vary too
much. If you're adding Vitest / Bun test:

**Unit-test the text renderers.** Because `renderText` is a pure function of
`data`, you can test it without running the whole command:

```typescript
import { renderLogLevel } from "../commands/log-level"; // export the fn
test("renderLogLevel shows source", () => {
  expect(renderLogLevel({ current: "debug", source: "env" })).toBe(
    "Log level: debug (env)"
  );
});
```

**Integration-test commands** by capturing streams. Use `node:stream`'s
`Writable` to swap `process.stdout` / `process.stderr` during a test, call
`runMain(testCommand)`, then parse the captured output (for JSON mode,
`JSON.parse` the captured line; for text mode, match against expected strings).

**Mock `global.fetch`** for api-client tests. Don't try to stub `apiFetch`
itself — the whole point is that the fetch shape is stable; mocking the next
layer up is more robust.

**Don't mock the envelope emitter.** `emit` / `emitError` are simple enough that
testing them against real streams is cheaper and catches stream-handling bugs
that mocks miss.

## Gotchas

Most of these are documented inline in the generated code — the table below
points to where. The short version lives here for quick reference.

| Gotcha                                                            | File                                               |
| ----------------------------------------------------------------- | -------------------------------------------------- |
| Errors → stderr; JSON must not contain ANSI; `data.warnings[]`    | `agent-layer.ts` (file header)                     |
| Citty doesn't inherit root flags                                  | `cli.ts` (file header)                             |
| Help interceptor ordering + bypasses future root flags            | `cli.ts` (inline, interceptor block)               |
| Never default secret flags (manifest leak)                        | `manifest.ts` (file header)                        |
| Boundary cast for `CittyCommand`; citty `Resolvable<T>` surprises | `manifest.ts` (type header + walker)               |
| TTY cached at module load + `setColorOverride` escape hatch       | `styles.ts` (file header)                          |
| No `import.meta.dir` for project root — walk up from cwd          | `paths.ts` (file header)                           |
| `token: ""` vs `undefined`                                        | `api-client.ts` (file header + FetchOptions jsdoc) |
| Dev-server watch caveat for touch-reload                          | `reload.ts` (file header)                          |
| Scope inherited via walker, not introspectable from sub meta      | `define.ts` (design note comment)                  |
| `SCOPE_ORDER` derivation from label map                           | `help-renderer.ts` (inline)                        |

**Non-obvious items worth calling out here** (these aren't in generated comments
because they matter when extending, not when reading the code):

- **Don't emit on stderr in a JSON success path.** It contaminates captured
  streams. Warnings that belong in the output go in `data.warnings[]`, not
  `console.warn`. Only true errors hit stderr.
- **`meta.command` must be the space-joined path** (`"library list"`). It's the
  grouping key agents use to distinguish envelopes in pipelines — the leaf name
  alone collides.
- **Don't default secret values.** The manifest walker serializes `default`
  verbatim; a defaulted `--token` leaks to `help --json`. Default to `null` and
  read the secret inside `run(ctx)`.

## Related Work

- **[`create-project-cli`](https://github.com/ichabodcole/seed-project-cli)** —
  the installer that emits the scaffold this skill describes.
- **`zed-biome-husky-quality-gates`** (sibling recipe) — recommended setup for
  Biome + Husky + lint-staged in a Bun project. Install separately; this CLI
  does not depend on it.
- **Short-ID prefix resolver** — if you find yourself pairing the client helper
  with a server-side `idPrefix` filter across multiple projects, consider
  extracting it as its own recipe covering both halves.
