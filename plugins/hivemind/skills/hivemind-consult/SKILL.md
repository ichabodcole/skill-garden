---
name: hivemind-consult
description:
  Consult HiveMind (the cross-project knowledge base) from inside a working
  project — find and apply relevant playbooks, scenarios, and feedback for the
  task at hand, and flag when current work runs afoul of a principle HiveMind
  already recorded. Triggers on "what does HiveMind know about X", "check this
  against HiveMind", "is there a playbook for X", "consult HiveMind", "are we
  breaking anything we've learned". Searches via Operator MCP by frontmatter and
  content. Can materialize a playbook or principle into the project's local
  docs/ with provenance. Does NOT write new knowledge to HiveMind (use
  hivemind-capture/hivemind-feedback) or promote/triage (use hivemind-digest).
---

# HiveMind Consult

This is the dispersal direction: reading from HiveMind into the work in front of
you. From inside a working project you pull the playbooks, scenarios, and
feedback that bear on the current task, check what you're about to do against
the principles HiveMind already recorded, and — when it helps — materialize a
doc down into the project's local `docs/`. This skill only reads. Writing new
knowledge is `hivemind-capture` / `hivemind-feedback`; triage and promotion is
`hivemind-digest`.

## When to use

- You're starting a known kind of activity — a migration, a new skill, a recipe
  extraction, a release — and want to lead with whatever HiveMind has learned.
- You're mid-task and want to check current work against prior learnings before
  it calcifies.
- You hit a problem and want to look for a prior solution before reinventing it.

## Modes

### Pull

Given the activity, search HiveMind across all five folders by `type`, `tags`,
`stack`, `applied_to`, and full-text content. Surface the most relevant entries,
say why each matched, and apply them to the task at hand. Prefer entries already
`applied_to` similar projects. If nothing matches, say so — don't stretch.

### Guardrail

Compare the current work against recorded scenarios and principles, and flag
anything that violates one. Name the principle, point at the offending spot, and
propose the fix.

Worked example: a skill draft that spells out tool names the agent can already
discover at runtime violates the `only-include-non-discoverable-information`
principle. Flag it, cite the slug, and suggest replacing the hardcoded names
with "discover the tool names from your runtime."

The principles most worth checking against (reference them by slug):

- `only-include-non-discoverable-information`
- `affirmative-scope-over-defensive-exclusion`
- `intentional-design-for-feedback-loops`

### Materialize

When an entry deserves a local home, bring it into the project's playbooks — the
one place project-docs keeps guidance (`memory` and `lesson` are retired types):

- **A playbook** goes to `docs/playbooks/`, shaped Goal · Steps · Verification.
  If the project already has a playbook for that kind of work
  (`bun scripts/pdocs/cli.ts find --type playbook`), merge into it; otherwise
  create one with `bun scripts/pdocs/cli.ts new playbook <slug>`, which also
  writes its catalog line in `docs/index.md`.
- **A scenario or lesson** becomes a **Step and a Verification appended to the
  playbook for that kind of work** — an instruction the next agent follows, and
  how it can tell the step was done — not a narrative page of its own.

Record provenance so the local copy points back at its source — in the body,
beside what you added, because the project's lint rejects frontmatter keys its
schema does not declare (`UNKNOWN FIELD`):

```markdown
_From HiveMind `<doc id>`, retrieved YYYY-MM-DD._
```

Materializing makes a snapshot — it does not sync. If the source changes later,
re-materialize.

## Reading the Field Guide

At preflight, read the sibling `./field-guide.md` for the group IDs, project ID,
and search fields you'll need. The live **HiveMind Field Guide** document in the
workspace is canonical — when Operator is reachable, prefer it over the local
snapshot.

## What this skill needs

- Operator MCP with HiveMind READ scope. Discover the actual tool names from
  your runtime — do not hardcode them.
- A HiveMind credential, per the Field Guide. It lives in the local `.operator`
  config, conventionally under `OPERATOR_HIVEMIND_ADMIN_*`. If it's absent, ask
  the user rather than guessing.

Search the HiveMind project `bMxQv-R9IXHVl8jlACagv` across all five folders by
group ID — never by name:

- Playbooks — `R4uC0jYDig8_pylpkHTMP`
- Feedback — `c1X2fuiDRd6i7AQfCVm84`
- Scenarios — `9vDJ9VOBqgd0g6FEV0oQQ`
- Lessons Learned — `25izJ8swJEYP0B23UhZz0`
- @operator — `UerSKStBeWvJJ_im2tb0Q`

If a group ID fails to resolve, surface it to the user and STOP — do not
recreate the folder.

## Edge cases

- **No relevant entries.** Say so plainly. Don't force a weak match into
  guidance — "HiveMind has nothing on this" is a useful answer.
- **Operator auth fails.** Degrade gracefully: report "couldn't reach HiveMind,"
  then continue the underlying work without it.
- **No `docs/playbooks/`.** Create it (`bun scripts/pdocs/cli.ts new playbook`
  does), or ask the user where the guidance should live. Never create
  `docs/lessons-learned/`.
