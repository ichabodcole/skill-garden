---
name: hivemind-digest
description:
  Digest accumulated HiveMind knowledge (the cross-project knowledge base) —
  triage the Feedback and Scenarios folders, cluster by emergent theme, run a
  generalization pass, and propose promotions into Playbooks or Lessons Learned.
  Triggers on "digest HiveMind", "process the HiveMind backlog", "triage
  HiveMind feedback", "what should we promote in HiveMind", "synthesize
  HiveMind". Triage-and-propose, not triage-and-apply — surfaces a review-ready
  proposal for the user before writing. Reads/writes via Operator MCP. Does NOT
  capture new scenarios/feedback (use hivemind-capture/hivemind-feedback) or
  apply knowledge into a project (use hivemind-consult).
---

# HiveMind Digest

HiveMind Digest is the **stomach** of the knowledge cycle: it takes the raw
intake — accumulated Feedback and Scenarios — and turns what has earned it into
durable, reusable knowledge (Playbooks and Lessons Learned). It is the
counterweight to easy capture: capture is generous, digest is discerning. The
skill is **triage-and-propose, never triage-and-apply** — it surfaces a
review-ready proposal and writes promotions only after you approve them.

## Why this skill exists

Feedback and scenarios accumulate. Left untended they become a backlog of latent
improvements — and a few latent mistakes, if applied blindly. Ad-hoc promotion
is error-prone: it's easy to over-promote (every observation becomes a playbook,
and the knowledge base bloats) or under-promote (real cross-project signal stays
buried in single-instance feedback). This skill is the disciplined pass that
turns intake into knowledge with judgment.

## The three phases

### Phase 1 — Triage & propose

1. Inventory the Feedback and Scenarios folders (by group ID).
2. Read each entry fully. Distinguish three kinds of content:
   - **Promotable signal** — a claim or pattern that may generalize across
     projects.
   - **Already-promoted** — material that has a downstream playbook/lesson
     already; note it, don't re-promote.
   - **Not-yet-ripe** — a single-instance observation that hasn't recurred and
     has no strong general claim. Leave it.
3. Cluster promotable signal by emergent theme — let the clusters arise from the
   entries, don't force a pre-chosen taxonomy.
4. For each cluster, run the **generalization pass** (see the bar below).
5. Write a proposal — what to promote, to where (Playbook or Lessons Learned),
   with the reasoning. Do NOT write any promotion yet.

### Phase 2 — Review & align

Present the proposal to the user. For each proposed promotion, the outcome is
one of: accept, accept-with-modification, defer, or reject. Capture the
reasoning, especially for rejects — that reasoning is itself signal for next
time. This is the gate: nothing is written without the user's say-so.

### Phase 3 — Apply, archive, calibrate

For each accepted promotion:

1. Write the new Playbook or Lessons Learned entry (via Operator MCP), following
   the Field Guide's frontmatter for that type.
2. Mark the source entry/entries with a pointer to the promotion (a
   back-reference in frontmatter or a note) — don't delete them; provenance
   matters.
3. Record what was promoted so the next digest run doesn't re-litigate it.

## Bar for inclusion — judgment, not a count threshold

There is no hard "must appear in N reports" rule. For each cluster, ask:

- **Does the general claim help the next project?** Would a future agent, in a
  different project, do better work for having this as a playbook or lesson?
- **Or is this a specific case that won't generalize?** Some observations are
  true and useful once but would be noise as durable knowledge — they make the
  base heavier without making it sharper.
- **Or is the author flagging it load-bearing despite n=1?** A single-instance
  item can still promote when the author explicitly identified a load-bearing
  miss or a structural blind spot. Single-instance items that are merely
  _interesting_ don't.

If you can't articulate why a cluster's general form would help the _next_
project, it probably shouldn't promote yet. Note it as "considered, not
promoted" with reasoning — that record is itself useful next time.

## Promotion targets

Two promotion paths, both gated on the bar above:

- **feedback → playbook.** When a feedback signal is validated across ≥2
  projects, abstract it into a reusable how-to in the Playbooks folder. Set
  `applied_to` to the projects that warrant it and `last_verified` to today.
- **feedback and/or scenarios → lessons-learned.** When a cluster synthesizes
  into an issue→resolution writeup or a cross-cutting insight, write it to the
  Lessons Learned folder.

Mark every promoted source with a pointer back to what it became (a frontmatter
back-reference or a note) rather than deleting it — provenance matters, and the
next digest run needs to see what's already been lifted.

## Reading the Field Guide

At preflight, read the sibling `./field-guide.md` for the promotion ladder,
frontmatter shapes, and group IDs. The Field Guide is a local snapshot; **the
live HiveMind Field Guide document is canonical** — prefer it when reachable,
and fall back to the sibling file otherwise.

## What this skill needs

- **Operator MCP** with HiveMind read and write scope. Discover the exact tool
  names from your runtime's tool documentation at the moment of use — do not
  hardcode them here.
- **The HiveMind credential** per the Field Guide: look in the local `.operator`
  file, conventionally named `OPERATOR_HIVEMIND_ADMIN_*`. Treat that spelling as
  a local convention and ask the user if it is absent.

## Procedure (compact)

0. **Preflight.** Read the Field Guide; ensure a live HiveMind session.
1. **Inventory.** List the Feedback and Scenarios folders by group ID.
2. **Read.** Read each entry fully — don't triage from titles.
3. **Cluster.** Group promotable signal by emergent theme.
4. **Generalization pass.** Apply the bar to each cluster.
5. **Propose.** Write up what to promote, where, and why. Write nothing yet.
6. **Review.** Present to the user; capture accept/modify/defer/reject +
   reasons.
7. **Apply.** For each accepted item, write the Playbook/Lessons-Learned entry
   and mark the source(s) with a provenance pointer.
8. **Report.** Summarize what was promoted, deferred, and rejected.

Never write a promotion before step 6. The skill is triage-and-propose; the
user's approval is the gate.

## Stable group IDs

Reference folders by ID, never by name. If an ID fails to resolve, the folder
was changed — surface it to the user and STOP; do not recreate it.

| Resource             | Group ID                |
| -------------------- | ----------------------- |
| Project ("Hivemind") | `bMxQv-R9IXHVl8jlACagv` |
| Feedback (source)    | `c1X2fuiDRd6i7AQfCVm84` |
| Scenarios (source)   | `9vDJ9VOBqgd0g6FEV0oQQ` |
| Playbooks (target)   | `R4uC0jYDig8_pylpkHTMP` |
| Lessons Learned      | `25izJ8swJEYP0B23UhZz0` |

## Edge cases

- **First run / nothing ripe.** If nothing meets the bar yet, say so — an empty
  digest is a valid outcome, not a failure.
- **Operator auth fails.** Surface it and stop; don't half-process.
- **Conflicting signals across entries.** Two entries recommend opposite things.
  Surface the conflict explicitly in the proposal rather than silently picking
  one; the resolution may itself be a lesson.
- **A single-instance item flagged load-bearing.** Allowed to promote, but apply
  the bar honestly — load-bearing means a structural miss, not just interesting.
