---
type: cycle
title: Repository foundations
description:
  Make skill-garden check every change before it lands and version each plugin
  from its own commits.
tags: [tooling, release, ci]
status: draft
lifecycle: closed
started: 2026-09-29
appetite:
  Stop when a commit that breaks formatting, the docs gate or a plugin manifest
  can't land, and a commit to one plugin proposes a release of that plugin
  alone.
after: []
generated: { by: claude-opus-5-5, at: 2026-09-29 }
closed: 2026-09-29
---

# Repository foundations

## Why now

skill-garden was cut from project-docs today with none of the repository tooling
a public marketplace needs: no license, no formatter, no gate before a commit or
in CI, and versions bumped by hand across five plugins. Every later cycle
changes plugins, and each of those changes is safer once it is checked and
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
  versioned and changelogged from its own commits, and the recipe corrected from
  what the run finds.
- **item/fix-bridge-agent-tool-names** — `bridge-agent` names only tools the
  Agent Bridge server offers.
- **item/readme-marks-ecosystem-plugins** — the README says which plugins need
  the author's software.

Out of scope, deliberately: the two HiveMind chores (plugin content, better done
together in a HiveMind cycle), and the research on reaching runtimes other than
Claude Code (open-ended, and better answered once the release process exists).
The `html-mockup-prototyping` skill that project-docs also carries needs nothing
here: it belongs in `toolbox`, and project-docs is removing its copy.

## Outcome

Everything in scope shipped, on the day the cycle opened. The repository has an
MIT license and a gate, `bun run check`: Biome, Prettier on Markdown, `tsc`,
`pdocs check`, and `claude plugin validate --strict` on the marketplace and each
plugin. The pre-commit hook runs the gate, and so does CI on every push and pull
request. `claude plugin validate` needs no credentials, so CI needs no secrets.
Each plugin now gets its version and changelog from its own commits. The first
release, recipes 2.4.1, proposed only that plugin, as the dry runs predicted.
The two fixes found while writing the manifesto landed too: `bridge-agent` names
the tools the server offers, and the README says what each plugin needs. Nothing
was cut or carried over.

What was learned:

- **Recipes improve when they are used.** Applying the release-please recipe
  here corrected it in seven places. The one that mattered: release-please's
  generated changelogs fail Prettier, which would have made the hook refuse
  every commit after the first release. Applying a new recipe to a real project
  before calling it done is worth keeping as a habit.
- **Agent worktrees start from the first commit, not `develop`.** Every agent
  had to reset its worktree to `develop` first. Brief the next cycle's agents
  with the expected base commit.
- **Pushing `main` is the owner's step.** This session's permission check
  refuses it as a deploy, so plan for a hand-off at release time.
- **Leave a required check off `main` for now.** Release PRs, opened with the
  workflow's own token, get no checks.

The next cycle's natural core is
[the writing plugin](../items/writing-plugin.md), still in triage.

## Sessions

<!--
One line per branch, appended by `init-branch` as it opens them:

  - feature/some-branch (open)

`finalize-branch` rewrites `(open)` as `(landed YYYY-MM-DD)` when the branch
lands. Leave this section empty until the first branch; do not carry a
placeholder line into a real cycle.
-->

- chore/quick-fixes (landed 2026-09-29)
- feature/release-please-recipe (landed 2026-09-29)
- chore/quality-gates (landed 2026-09-29)
- chore/ci-workflow (landed 2026-09-29)
- chore/release-please-per-plugin (landed 2026-09-29; released as recipes 2.4.1)
