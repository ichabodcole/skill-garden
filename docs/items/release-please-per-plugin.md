---
type: item
title: Version each plugin with release-please
description:
  Plugin versions are bumped by hand in plugin.json; release-please in manifest
  mode, with one package per plugin, would bump each from its own conventional
  commits and keep a changelog per plugin.
status: draft
lifecycle: active
id: 01a0ee8e-de57-747a-95a2-cd9254305a1c
kind: task
generated: { by: claude-opus-5-5, at: 2026-09-29 }
cycle: 2026-09-foundations
blocked_by: [01a0ee90-2917-71be-a8bf-c407123d41ce]
---

# Version each plugin with release-please

Each plugin's version lives in its `plugin.json` and is bumped by hand (minor
for a behaviour change, patch for typos and formatting). With five plugins, that
is easy to forget, and nothing records what changed in each version.
release-please in manifest mode, with one package per plugin directory, would
bump each from the conventional commits that touch it, write the new version
into its `plugin.json`, and keep a changelog per plugin. project-docs uses
release-please for its scaffold, and its config is a reference.

## Definition of done

- [x] A release-please workflow and manifest config with one package per plugin,
      each updating `plugins/<name>/.claude-plugin/plugin.json`'s `version` and
      its own `CHANGELOG.md`.
- [ ] A commit touching one plugin proposes a release of that plugin only, and a
      docs-only commit proposes none.
- [x] `AGENTS.md` says how versions are bumped now.

The second box holds in a local dry run
(`release-please release-pr --dry-run --local` against a clone whose `main` is
this branch) but is unticked until the action has run on GitHub: the first run
after this lands on `main` should propose `recipes` 2.4.1 from its
`fix(recipes)` commit, and nothing for a plugin no `feat` or `fix` has touched
since `bootstrap-sha`.

Best done with [the release-please recipe](./release-please-recipe.md), as its
first real use.
