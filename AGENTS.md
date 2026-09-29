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

- Bump the plugin's `version` in its `plugin.json` with every change: minor for
  any change in behaviour, patch only for typos and formatting.
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

## Branches

Work branches from `develop` and lands back on it; `main` is what the
marketplace serves.
