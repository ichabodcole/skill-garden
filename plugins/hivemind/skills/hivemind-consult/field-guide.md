# HiveMind Field Guide

HiveMind is the cross-project knowledge base: work done in one project produces
reusable knowledge that flows up (collect), gets refined (digest), and flows
back down to other projects (disperse). The **live workspace is the source of
truth** — this document only records its conventions so the four sibling skills
(`hivemind-capture`, `hivemind-feedback`, `hivemind-consult`, `hivemind-digest`)
read one consistent reference at preflight.

## Document types

| Type            | Folder          | What it is                                                                                                                  | Bar                                            |
| --------------- | --------------- | --------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| scenario        | Scenarios       | A human↔agent decision/thinking delta from implementation work, distilled into a named reusable takeaway                   | High — "worth re-reading in six months"        |
| feedback        | Feedback        | A signal about a skill/process/mechanism, often from an end-of-run feedback touchpoint, aimed at improving the tool/process | Lower — hypothesis-shaped / single-instance OK |
| playbook        | Playbooks       | An abstracted, reusable how-to validated across projects                                                                    | Promoted, not authored directly                |
| lessons-learned | Lessons Learned | An issue→resolution writeup or a synthesis across scenarios                                                                 | Promoted via digest                            |

## Capture vs. feedback

The distinction is by **subject, not maturity**.

- **Capture (scenario)** is about how to _think_ — a human↔agent decision delta
  that surfaces during implementation work. The human pushes back on the agent's
  approach, or a non-obvious decision gets made, and the takeaway generalizes.
  - _Example:_ the agent proposed adding a new column for a soft-delete flag;
    the human pushed back and the team settled on a `deleted_at` timestamp
    instead because it carries the "when" for free. The reusable takeaway:
    prefer nullable timestamps over boolean flags for lifecycle state.
- **Feedback** is about how a _tool/process performed_ and how to improve it —
  often surfaced at a skill's end-of-run feedback touchpoint ("any issues using
  this skill?").
  - _Example:_ the `generate-dev-plan` skill kept re-reading the whole proposal
    on each step; feedback proposes it cache the proposal summary up front to
    cut token churn.

A single observation is feedback if it judges the mechanism, and a scenario if
it captures a way of thinking — regardless of how polished either one is.

## Scenarios are principles

There is no Principles folder. Named scenarios serve as the reusable principles
of HiveMind — a good scenario slug _is_ a principle a future reader can apply.
Digest promotes patterns _across_ scenarios into Playbooks (reusable how-tos) or
Lessons Learned (syntheses), but the scenario itself is the unit of principle.
(This may be revisited if a real Principles tier is later warranted.)

## Promotion ladder

Promotion is **judgment-based, not a fixed count**. The bar is always "does the
general claim help the next project," and a load-bearing single-instance item
can still qualify.

- **feedback → playbook** — when a feedback signal is validated across ≥2
  projects, abstract it into a reusable how-to.
- **feedback and/or scenarios → lessons-learned** — when synthesis across items
  yields an issue→resolution writeup or a cross-cutting insight.
- **scenarios stand alone as principles** — a named scenario needs no promotion
  to be useful; it is already a reusable takeaway.

Do not gate promotion on a literal "≥2 projects" tally. Two projects is the
typical signal for a playbook, but a single observation with a strong,
transferable general claim can promote on its own merits.

## Frontmatter by type

```yaml
type: scenario
date: <YYYY-MM-DD>
source_project: <project label>
slug: <kebab-case-takeaway>
```

```yaml
type: feedback
date: <YYYY-MM-DD>
originated_in: [<project>]
tags: [<...>]
# optional: proposes, impact, generalization
```

```yaml
type: playbook
status: stable | draft
tags: [<...>]
stack: [<...>]
applied_to: [<project>, ...]
last_verified: <YYYY-MM-DD>
```

## Stable group-ID map

ALWAYS reference folders by ID, never by name — names can be edited, IDs are
stable.

| Resource             | ID                      |
| -------------------- | ----------------------- |
| Project ("Hivemind") | `bMxQv-R9IXHVl8jlACagv` |
| Playbooks            | `R4uC0jYDig8_pylpkHTMP` |
| Feedback             | `c1X2fuiDRd6i7AQfCVm84` |
| Scenarios            | `9vDJ9VOBqgd0g6FEV0oQQ` |
| Lessons Learned      | `25izJ8swJEYP0B23UhZz0` |
| @operator            | `UerSKStBeWvJJ_im2tb0Q` |

**Rule:** if an ID fails to resolve, the folder was changed — surface this to
the user and STOP. Do NOT recreate the folder; downstream references to the old
ID would break.

## Slug rules

- kebab-case, 4–7 words.
- Name the **takeaway**, not the situation. A good slug describes what a future
  reader will learn; a bad slug names the conversation or feature where it
  surfaced.
  - Good: `prefer-timestamps-over-boolean-lifecycle-flags`
  - Bad: `auth-refactor-tuesday-discussion`
- Scenario document filename is `<YYYY-MM-DD>-<slug>.md`.

## Credentials & access

Access is via the Operator MCP, set up through the `operator-setup` flow (from
the sibling `operator` plugin). Look for the HiveMind credential in the local
`.operator` file — conventionally named `OPERATOR_HIVEMIND_ADMIN_*`, but treat
that spelling as a _local convention_ and ask the user if it is absent.

Discover the exact MCP tool names from your own runtime's tool documentation at
the moment of use — do not assume them from this guide. (This rule follows a
HiveMind principle: only include information that is not easily discoverable.)
