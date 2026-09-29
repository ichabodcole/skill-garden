# AGENTS.md

Guidance for AI coding assistants working in this repository.

## What this is

A Claude Code plugin marketplace (`.claude-plugin/marketplace.json`) holding
plugins that are still growing: skills that started elsewhere and aren't yet big
enough for a repository of their own. Each plugin lives in `plugins/<name>/`,
with its manifest at `plugins/<name>/.claude-plugin/plugin.json` and its skills
under `plugins/<name>/skills/`. A plugin that outgrows this place graduates to
its own repository.

## Changing a plugin

The steps are in
[docs/playbooks/change-a-plugin-playbook.md](./docs/playbooks/change-a-plugin-playbook.md),
and releasing in
[docs/playbooks/release-playbook.md](./docs/playbooks/release-playbook.md). The
rules:

- Don't bump `version` in `plugin.json` by hand. release-please bumps it from
  the conventional commits that touch `plugins/<name>/`, and writes that
  plugin's `CHANGELOG.md`, in a release PR on `main`; merging the PR releases.
- Type and scope each plugin commit by what it changes for the plugin's user:
  `feat(hivemind): ...` for a change in behaviour or in what a skill tells the
  agent (minor), `fix(hivemind): ...` for a correction (patch), `feat!:` or a
  `BREAKING CHANGE:` footer for a major (a minor below 1.0). A skill change
  typed `docs`, `chore` or `style` releases nothing, and so does any commit
  outside `plugins/`, so a typo or wording fix to a skill is `fix(<plugin>)`.
  Removing or renaming a skill is breaking. A commit touching two plugins
  counts, with its one type, toward both.
- To force a version, add a `Release-As: x.y.z` footer to a `feat` or `fix`
  commit that touches that plugin only. An empty commit touches every plugin, so
  its `Release-As:` sets them all to that version.
- A new plugin: add it to `release-please-config.json` and its version to
  `.release-please-manifest.json` in the commit that adds it.
- A skill's paths are relative to its plugin. Don't reach into another plugin's
  installed folder from a skill: each plugin is installed on its own. A skill
  that works in a clone of this repository (as `create-recipe` does) may name
  another plugin's files there, by the clone's path.

## Documentation

This repository's docs follow the project-docs scaffold (`docs/`, generated at
9.2.0). The structure and contract are in [docs/README.md](./docs/README.md) and
[docs/SCHEMA.md](./docs/SCHEMA.md).

## Documentation CLI

Create documents with the `pdocs` CLI, not by hand:
`bun scripts/pdocs/cli.ts new <type> <name>`. Run
`bun scripts/pdocs/cli.ts --help` for what else it does. `check` is the docs
gate.

## Quality gate

Run `bun install` once; it also installs the pre-commit hook. Then
`bun run check` is the gate: Biome on the JSON (and any TypeScript outside the
vendored `scripts/pdocs/`), Prettier on the Markdown, `tsc`, the docs check, and
`claude plugin validate --strict` on the marketplace and every plugin. The
pre-commit hook formats the staged files and runs the same gate, and refuses the
commit if it fails. `bun run format` fixes formatting. CI
(`.github/workflows/check.yml`) runs the same gate on every push and pull
request.

The files the project-docs scaffold ships (`scripts/pdocs/`, `docs/SCHEMA.md`,
the category READMEs, the templates, `docs/STYLE.md`) are left out of
formatting, as project-docs leaves them, so a migration doesn't churn them.

## Branches

Work branches from `develop` and lands back on it; `main` is what the
marketplace serves. After merging a release PR on `main`, merge `main` back into
`develop` straight away, so `develop` carries the new versions.
