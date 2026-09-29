---
type: cycle
title: Repository foundations
description:
  Make skill-garden check every change before it lands and version each plugin
  from its own commits.
tags: [tooling, release, ci]
status: draft
lifecycle: active
started: 2026-09-29
appetite:
  Stop when a commit that breaks formatting, the docs gate or a plugin manifest
  can't land, and a commit to one plugin proposes a release of that plugin
  alone.
after: []
generated: { by: claude-opus-5-5, at: 2026-09-29 }
---

# Repository foundations

## Why now

skill-garden was cut from project-docs today with none of the repository
tooling a public marketplace needs: no license, no formatter, no gate before a
commit or in CI, and versions bumped by hand across five plugins. Every later
cycle changes plugins, and each of those changes is safer once it is checked and
versioned automatically. Two small fixes found while writing the manifesto ride
along, because they are cheap and make the marketplace honest to its users.

## Scope

In order: the formatting commit from the quality gates lands before
release-please is watching, so it cuts no release of every plugin.

- **item/add-a-license** — an MIT `LICENSE` at the root, matching what every
  `plugin.json` already claims.
- **item/quality-gates** — the zed-biome-husky recipe applied, and a pre-commit
  hook that refuses a commit failing formatting, `pdocs check` or
  `claude plugin validate`.
- **item/ci-workflow** — the same gate on every push and pull request.
- **item/release-please-recipe** — a release-please recipe in the recipes
  plugin, surveyed from 13 projects.
- **item/release-please-per-plugin** — the recipe's first use: each plugin
  versioned and changelogged from its own commits, and the recipe corrected
  from what the run finds.
- **item/fix-bridge-agent-tool-names** — `bridge-agent` names only tools the
  Agent Bridge server offers.
- **item/readme-marks-ecosystem-plugins** — the README says which plugins need
  the author's software.

Out of scope, deliberately: the two HiveMind chores (plugin content, better
done together in a HiveMind cycle), and the research on reaching runtimes other
than Claude Code (open-ended, and better answered once the release process
exists). The duplicate `html-mockup-prototyping` between `toolbox` and
project-docs is not filed yet.

## Outcome

_Written at close, not before._

## Sessions

<!--
One line per branch, appended by `init-branch` as it opens them:

  - feature/some-branch (open)

`finalize-branch` rewrites `(open)` as `(landed YYYY-MM-DD)` when the branch
lands. Leave this section empty until the first branch; do not carry a
placeholder line into a real cycle.
-->
