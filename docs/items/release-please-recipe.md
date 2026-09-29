---
type: item
title: Write a release-please recipe
description:
  Almost every project uses release-please, set up slightly differently each
  time; a recipe would show an agent how to set it up and which of its
  variations fits the project.
status: draft
lifecycle: done
id: 01a0ee90-2917-71be-a8bf-c407123d41ce
kind: task
generated: { by: claude-opus-5-5, at: 2026-09-29 }
scope: recipes
cycle: 2026-09-foundations
---

# Write a release-please recipe

Almost every project Cole starts uses release-please, and each sets it up a
little differently. There's no recipe for it, so each setup is re-derived, and
what one project learned doesn't reach the next. A `release-please` recipe in
the recipes plugin would let a future project say "use the release-please
recipe": the agent sets it up, and chooses the variation that fits.

**Start from what already exists.** 13 local projects have a
`release-please-config.json`:

- `project-starters/project-docs`
- `project-starters/alb-project-scaffolding-system`
- `Spellbook`
- `wocky-talky`
- `agent-cli-conformance`
- `comfy-gateway`
- `dsh-plugin-monitor`
- `Hypnotyche/tts-conductor`
- under `dreamwood/`: `anthill`, `dream-flute`, `media-buffet`, `media-forge`,
  `story-loom`

Read each project's config, manifest and workflow, sort the differences into the
ones that follow from the project's shape and the ones that are accidents, and
write the recipe around the first kind.

**Variations the recipe should cover** (a starting list; the survey decides):

- **Single package or monorepo:** `"."` alone, or manifest mode with one package
  per directory (plugins, apps, workspaces).
- **Release type:** `node`, `simple`, and others; where the version lives
  (`package.json`, or other files through `extra-files` with generic, JSON-path
  or `x-release-please-version` markers).
- **Commits that shouldn't release:** `exclude-paths` for paths that ship
  separately. project-docs excludes `plugins/` and `dist/` so a plugin-only
  commit cuts no scaffold release. Hidden changelog sections (`chore`, `docs`)
  produce no release.
- **Branch strategy:** release PRs against `main` while work lands on `develop`,
  and syncing `develop` back after a release.
- **Pre-1.0 behaviour** (`bump-minor-pre-major`) and changelog sections.
- **Known traps, from project-docs' history:**
  - release-please's history walk stops at the last release commit, so
    fast-forwarding a long `develop` onto a `main` that just cut a patch release
    can propose the wrong version. `Release-As:` fixes it.
  - Squashing a branch can change whether its commits count, when a squash
    merges excluded and included paths into one commit.
  - A release PR's own branch may have no checks, so merge on the main branch's
    checks.
  - Every release rewrites the version files. Tests must derive those values,
    not pin them.

## Definition of done

- [x] A `release-please` recipe in `plugins/recipes/skills/recipes/library/`,
      written with the `create-recipe` skill, listed in the recipes index.
- [x] It sets up a default for a single-package project, and says which
      variation to choose for each situation above, with a config for each.
- [x] Its known-traps section names each trap, how to spot it, and the fix.
- [x] It is applied first to
      [versioning each plugin](./release-please-per-plugin.md) in this
      repository, and corrected from what that run finds.
