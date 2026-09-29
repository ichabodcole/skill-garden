# Zed + Biome + Husky Quality Gates Recipe

## Purpose

Configure Biome as the single source of truth for formatting and linting, wire
Zed to use Biome for format-on-save, and enforce quality gates via Husky
pre-commit hooks that block commits when formatting, lint, typecheck, or tests
fail. The core value is eliminating configuration drift between editor, CLI, and
git hooks so that what the developer sees on save is exactly what the commit
hook enforces.

## When to Use

- Setting up a new Bun/TypeScript project that needs consistent code quality
- Adding Biome to replace ESLint + Prettier
- Configuring Zed to format with Biome instead of default language servers
- Adding pre-commit hooks that enforce formatting, lint, types, and tests
- The project uses Vue/Nuxt and needs Biome to handle `.vue` files
- The project uses Tailwind CSS v4 directives that trip up default CSS parsers

## Technology Stack

| Layer             | Technology                     | Version |
| ----------------- | ------------------------------ | ------- |
| Runtime           | Bun                            | 1.2+    |
| Formatter/Linter  | Biome                          | 2.4+    |
| Editor            | Zed                            | Latest  |
| Git Hooks         | Husky                          | 9+      |
| Staged File Fixes | lint-staged                    | 16+     |
| Markdown Format   | Prettier (Biome doesn't do md) | 3+      |
| Monorepo (opt.)   | Turborepo                      | 2+      |

## Architecture Overview

```
Developer saves file in Zed
    ↓
Zed uses Biome formatter (via LSP)
    ↓
Developer commits
    ↓
Husky pre-commit hook fires
    ↓
lint-staged: auto-fix staged files via Biome
    ↓
Full check: typecheck → biome check → tests
    ↓
Commit succeeds or is blocked
```

The key design decision is making Biome the **single authority** for all
formatting and linting of code files. Prettier is used only for markdown (which
Biome doesn't support). This avoids the classic problem of editor formatters and
CLI formatters producing different output.

Three configuration files must stay in sync:

- `biome.json` — which file types Biome owns
- `.zed/settings.json` — which languages route to Biome for formatting
- `lint-staged` config — which globs get Biome auto-fix on commit

If these drift apart, files will format differently in different contexts.

## Implementation Process

### Phase 1: Install Dependencies

```bash
bun add -d @biomejs/biome husky lint-staged prettier
```

If the project uses Vue/Nuxt and `vue-tsc` complains about missing
`@vue/language-core`:

```bash
bun add -d @vue/language-core
```

Enable Husky via the `prepare` script in root `package.json`:

```json
"scripts": {
  "prepare": "husky"
}
```

Run it once to initialize:

```bash
bun run prepare
```

**Validate:** `ls .husky/` should show the hooks directory.

### Phase 2: Configure Biome

Create or update `biome.json` at the project root.

**Key decisions:**

1. **Explicitly scope `files.includes`** to the file types and paths Biome
   should own. Don't rely on defaults — be explicit about what's in and out.
2. **Enable HTML experimental support** if the project has Vue files. Both the
   `experimentalFullSupportEnabled` flag AND `html.formatter.enabled` are needed
   — the flag alone only enables linting, not formatting.
3. **Enable Tailwind CSS directive parsing** if the project uses Tailwind v4
   directives (`@theme`, `@custom-variant`, `@apply`, `@plugin`). Without this,
   Biome will fail to parse those CSS files.
4. **Exclude generated directories** with the `!!` prefix (Biome's negation
   syntax).

```json
{
  "$schema": "https://biomejs.dev/schemas/2.4.8/schema.json",
  "html": {
    "experimentalFullSupportEnabled": true,
    "formatter": {
      "enabled": true
    }
  },
  "css": {
    "parser": {
      "tailwindDirectives": true
    },
    "formatter": {
      "enabled": true
    }
  },
  "files": {
    "includes": [
      "packages/**/*.ts",
      "packages/**/*.tsx",
      "packages/**/*.json",
      "packages/**/*.jsonc",
      "packages/**/*.css",
      "apps/**/*.ts",
      "apps/**/*.tsx",
      "apps/**/*.vue",
      "apps/**/*.json",
      "apps/**/*.jsonc",
      "apps/**/*.css",
      "*.ts",
      "*.tsx",
      "*.json",
      "*.jsonc",
      "*.css",
      "!!**/dist",
      "!!**/node_modules",
      "!!**/.nuxt",
      "!!**/.output",
      "!!**/drizzle",
      "!!**/components/ui"
    ]
  },
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2,
    "lineWidth": 100
  },
  "linter": {
    "enabled": true,
    "rules": {
      "recommended": true
    }
  }
}
```

Adapt the `files.includes` paths and exclusions to match the project structure.
For non-monorepo projects, replace `packages/**/*` and `apps/**/*` with
`src/**/*` or whatever the project uses.

Add package scripts for CLI usage:

```json
"scripts": {
  "lint": "biome check --error-on-warnings .",
  "lint:fix": "biome check --write --error-on-warnings .",
  "format": "biome format --write .",
  "format:md": "prettier --write '**/*.md'"
}
```

The `--error-on-warnings` flag is critical. Without it, `biome check` exits
successfully even when it prints warnings, which means your lint gate silently
passes with actionable issues.

**Validate:**

- `bun run format` processes the intended file types (check output)
- `bun run lint` fails when there are warnings or errors
- Vue files are formatted, not just linted
- CSS files with Tailwind directives parse without errors

### Phase 3: Configure Zed

Create `.zed/settings.json` in the project root. This is a repo-local settings
file that Zed picks up automatically.

For each language Biome owns, set the formatter to `biome` and enable
format-on-save. For CSS with Tailwind, swap the CSS language server to the
Tailwind one to avoid false "unknown at-rule" diagnostics.

```json
{
  "languages": {
    "CSS": {
      "formatter": {
        "language_server": {
          "name": "biome"
        }
      },
      "format_on_save": "on",
      "language_servers": [
        "tailwindcss-intellisense-css",
        "!vscode-css-language-server",
        "..."
      ]
    },
    "TSX": {
      "formatter": {
        "language_server": {
          "name": "biome"
        }
      },
      "format_on_save": "on"
    },
    "TypeScript": {
      "formatter": {
        "language_server": {
          "name": "biome"
        }
      },
      "format_on_save": "on"
    },
    "Vue.js": {
      "formatter": {
        "language_server": {
          "name": "biome"
        }
      },
      "format_on_save": "on"
    }
  },
  "lsp": {
    "biome": {
      "settings": {
        "require_config_file": true
      }
    }
  }
}
```

The `require_config_file: true` setting prevents Biome from activating in
projects that don't have a `biome.json` — important in multi-project workspaces.

Add or remove language entries based on what the project uses. The key principle
is: **every language that Biome formats in `biome.json` must also be routed to
Biome in Zed settings.** If they diverge, saving in Zed will produce different
output than `bun run format`.

**Validate:**

- Save a `.ts` file in Zed — Biome formatting applies
- Save a `.vue` file — Biome formatting applies
- Save a `.css` file with Tailwind directives — no false diagnostics
- Run `bun run format` and confirm Zed and CLI produce identical output

### Phase 4: Wire Husky and lint-staged

**4.1 Configure lint-staged**

Add to root `package.json`:

```json
"lint-staged": {
  "*.{ts,tsx,vue,json,jsonc,css}": [
    "biome check --write --error-on-warnings --no-errors-on-unmatched"
  ],
  "*.md": [
    "prettier --write"
  ]
}
```

The glob pattern must cover **all** file types that Biome owns. If you add a new
file type to `biome.json`, add it here too. The `--no-errors-on-unmatched` flag
prevents lint-staged from failing when a staged file type has no Biome rules
(e.g., JSON files that only need formatting).

**4.2 Create the pre-commit hook**

Create `.husky/pre-commit`:

```sh
bunx lint-staged
bun run check
```

This runs in two stages:

1. `lint-staged` auto-fixes staged files (formatting + lint fixes)
2. `check` runs the full repository quality gate (typecheck + lint + tests)

**4.3 Define the check script**

Add to root `package.json`:

```json
"scripts": {
  "check": "turbo run typecheck && biome check --error-on-warnings . && bun run test"
}
```

For non-Turborepo projects, replace `turbo run typecheck` with the direct
typecheck command (e.g., `tsc --noEmit` or `nuxt typecheck`).

The `check` script must use Bun-backed test execution if the codebase imports
Bun APIs. Using raw `vitest run` instead of `bunx --bun vitest run` will fail on
`import { $ } from "bun"` and similar imports.

**Validate:**

- `bunx lint-staged` auto-fixes staged Biome-owned files
- `bun run check` fails on type, lint, or test regressions
- Commit with a known failure — hook blocks it
- Fix the issue and commit — hook passes without `--no-verify`

### Phase 5: Fix Drift Exposed by Stronger Gates

After enabling strict gates, the first run often surfaces pre-existing issues
that weaker hooks tolerated. Common fixes:

1. **Type errors** — run `bun run typecheck` and fix any errors. These were
   previously hidden by hooks that only ran lint, not typecheck.
2. **Non-null assertions** — Biome may flag `!` assertions that can be replaced
   with safer control flow.
3. **Export name collisions** — Nuxt/Volar auto-imports may warn about duplicate
   exports across composables. Rename one of the exports.
4. **Vue tooling warnings** — if `vue-tsc` prints
   `Cannot find module '@vue/language-core'`, install it as a root dev
   dependency (done in Phase 1).

Run the full gate to confirm everything is clean:

```bash
bun run check
```

Then attempt a real commit to verify the hook path end-to-end.

**Validate:**

- `bun run typecheck` passes
- `bun run lint` passes
- `bun run test` passes
- A real `git commit` succeeds on a clean working tree

## Gotchas and Trade-offs

### Vue files lint but don't format

**Symptom:** `biome check` recognizes `.vue`, but `biome format` ignores them.

**Cause:** `html.experimentalFullSupportEnabled` alone enables linting only. The
HTML formatter must also be explicitly enabled.

**Fix:** Add `html.formatter.enabled: true` in `biome.json`.

### Tailwind CSS directives show as invalid in Zed

**Symptom:** Zed underlines `@theme`, `@custom-variant`, `@apply`, or `@plugin`
in CSS files.

**Cause:** Zed is using the default CSS language server which doesn't know
Tailwind directives.

**Fix:** In `.zed/settings.json`, configure CSS buffers to use
`tailwindcss-intellisense-css` and disable `vscode-css-language-server`.

### Biome CLI and Zed format different file sets

**Symptom:** Saving in Zed reformats a file that `bun run format` ignores, or
vice versa.

**Cause:** The Zed language config and `biome.json files.includes` have drifted
apart.

**Fix:** Keep the three configs in sync — `biome.json`, `.zed/settings.json`,
and `lint-staged` globs.

### Lint appears to pass while warnings exist

**Symptom:** `bun run lint` exits 0 even with Biome warnings printed.

**Cause:** `biome check` does not fail on warnings by default.

**Fix:** Use `--error-on-warnings` everywhere: `lint`, `lint:fix`, `check`, and
lint-staged commands.

### Pre-commit passes staged fixes but misses some file types

**Symptom:** TS/Vue files are fixed, but JSON/CSS files slip through.

**Cause:** `lint-staged` glob doesn't cover all Biome-owned types.

**Fix:** Update the lint-staged glob whenever Biome ownership expands.

### Full check fails even though `bun test` passes locally

**Symptom:** `check` fails on tests inside pre-commit, but `bun test` works.

**Cause:** The `check` script invoked `vitest run` without Bun, but the codebase
imports Bun APIs.

**Fix:** Use `bunx --bun vitest run` or `bun run test` so the test runtime
matches the project's actual environment.

## Configuration Sync Checklist

When adding a new file type to the quality gate:

- [ ] Add to `biome.json` `files.includes`
- [ ] Add language entry in `.zed/settings.json` with `biome` formatter
- [ ] Add extension to `lint-staged` glob in `package.json`
- [ ] Verify: `bun run format`, Zed save, and commit all produce same result
