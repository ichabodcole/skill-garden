---
type: item
title: Write the plugin change and release playbooks
description:
  How to change a plugin and how to release lives in AGENTS.md fragments and one
  agent's memory; playbooks would let any agent, Claude or not, do both
  correctly.
status: draft
lifecycle: done
id: 01a0eed0-d4eb-770b-9023-d6959fa2f793
kind: task
generated: { by: claude-opus-5-5, at: 2026-09-29 }
---

# Write the plugin change and release playbooks

Two kinds of work recur here and have no playbook. Changing a plugin: the commit
type decides the release, removing or renaming a skill is breaking, and a new
plugin touches five files. Releasing: the owner pushes `develop:main`, merges
release-please's PR, and `develop` is fast-forwarded after. The rules are split
between `AGENTS.md` and one Claude session's memory, so an agent from another
runtime can't follow them. project-docs' `scaffold-update-checklist` covered the
first kind for that repository. Its plugin sections are the reference, less what
doesn't apply here: mirrored files, `dist/`, migrations, and plugin README
version histories.

## Definition of done

- [x] A playbook for changing a plugin and one for releasing plugins, each with
      Goal, Steps and Verification.
- [x] `AGENTS.md` says a typo fix to a skill is `fix(<plugin>)`, since `chore`
      releases nothing, and that removing or renaming a skill is breaking. It
      points to the playbooks.
- [x] The manifesto's recipe count is right, or worded so it can't go stale.
- [x] An agent that hasn't seen this work follows the change playbook on a trial
      change and reports nothing it had to guess. 2026-09-29: the trial ran, and
      every finding it reported is addressed in the playbooks and the
      release-please recipe.
