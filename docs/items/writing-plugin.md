---
type: item
title: Gather the writing skills into a writing plugin
description:
  Prose-review and writing-discipline skills live in agent-cli-conformance,
  project-docs and anthill, with three diverging copies of one; a writing plugin
  here would give them one home.
status: draft
lifecycle: triage
id: 01a0eeb5-f124-754a-91ef-93f5cdad9218
kind: task
generated: { by: claude-opus-5-5, at: 2026-09-29 }
---

# Gather the writing skills into a writing plugin

Skills for writing and reviewing prose grew up inside other projects and have no
shared home. Most are general and could be lifted out with little change. One,
`guidance-not-argument`, already exists as three copies that have drifted apart.
A `writing` plugin here would hold them. They need nothing from the author's
other software, so any developer could use them.

**Candidates** (surveyed 2026-09-29):

- From `agent-cli-conformance/.claude/`:
  - `skills/prose-cold-read`, its `references/CATALOGUE.md` (seven prose
    defects), and the `commands/prose-defect.md` command that adds entries to
    the catalogue. Coupling: hard-coded `.claude/skills/...` paths, and one
    catalogue example about acc.
  - `skills/ste-pass`, with `references/RULES.md` (ASD-STE100) and
    `scripts/sweep.sh`. Coupling: acc examples, hard-coded paths, and use of
    `/tmp`.
  - `skills/write-from-the-run`. No coupling.
  - `output-styles/plainspoken.md` and `output-styles/ste.md`. Check whether a
    plugin can ship an output style.
- `guidance-not-argument`, in three versions:
  - `agent-cli-conformance` (204 lines) and `project-starters/project-docs` (237
    lines). These share one method: cut a guidance document down to what its
    reader acts on.
  - `dreamwood/anthill` (183 lines, the newest). A different skill: write or
    rewrite a guidance document in plain prose.
  - Decide whether this is one skill or two, and which copy is the base for
    each.

**Not in scope:**

- project-docs' `scaffold-update-checklist`. It checks the scaffold's own
  consistency. Its one general step, a cold read by an unbriefed agent, is what
  `prose-cold-read` does.
- `repair-chain`, `two-lens-review` and `cascade-check`. They are methods for
  fixing defects in prose and code alike, not writing skills. They may deserve
  their own item.

The research notes behind these skills are in
`agent-cli-conformance/docs/research/`, from 2026-08-16 to 2026-08-27 (prose
density, prior art, cold reads, the cold-repair pipeline).

## Definition of done

- [ ] A `writing` plugin in the marketplace, holding the skills above, each free
      of paths and examples from the project it came from.
- [ ] `guidance-not-argument` has one source here, or two skills with distinct
      triggers, and the other copies are marked as replaced by it.
- [ ] Each lifted skill passes a cold read by an agent that has not seen its
      source project.
- [ ] The README lists the plugin, with "Nothing extra" under Needs.
