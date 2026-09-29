---
name: hivemind-feedback
description:
  File a signal about a skill, process, or mechanism into HiveMind's Feedback
  folder (the cross-project knowledge base). Use at the end of a skill run, or
  whenever a tool or process was rough, surprising, or improvable — the goal is
  to improve the tool/process itself, not to capture a way of thinking. Triggers
  on "file HiveMind feedback", "log feedback on this skill", "any issues using
  this skill", "send this to HiveMind feedback", and at a skill's end-of-run
  feedback touchpoint. Often hypothesis-shaped or single-instance. Writes via
  Operator MCP. Does NOT capture human↔agent decision deltas (use
  hivemind-capture) or promote feedback into playbooks (use hivemind-digest).
---

# HiveMind Feedback

Feedback is a signal about how a **skill, process, or mechanism** performed —
captured so the tool itself can get better. It is the on-ramp to HiveMind: often
hypothesis-shaped, frequently single-instance, surfaced in the moment a process
was rough, surprising, or improvable. This skill does one thing: file a clean
feedback entry into HiveMind's Feedback folder. It does NOT capture
decision/thinking deltas (that is `hivemind-capture`) or promote feedback into
playbooks and lessons (that is `hivemind-digest`).

## When to use

- **End-of-run feedback touchpoint** — a skill finished and asks "any issues
  using this skill?" The answer, if substantive, belongs here.
- **A tool or process was rough** — friction, a surprising failure mode, a
  confusing step, a workaround you had to invent. Capture it while it's fresh.
- **An improvable mechanism** — you see a concrete way a skill, command, or
  process could work better.
- **A structural observation** — something about how a process is shaped that
  warrants a second look, even if you're not sure of the fix yet.

## When NOT to use

- **A human↔agent decision or thinking delta** — if the insight is about how to
  _think_ about a problem (a judgment call, a lens-shift, a decision with
  non-obvious reasoning), that is a scenario — use `hivemind-capture`. The
  distinction is by subject, not maturity: feedback judges a _mechanism_, a
  scenario captures a _way of thinking_.
- **Subject-specific findings** — observations about a particular project's own
  code or content belong in that project's artifacts, not in HiveMind's
  cross-project Feedback folder.
- **A polished, validated pattern ready to reuse** — if it's already proven
  across projects, it may belong as a playbook (via `hivemind-digest`), not as
  raw feedback.

## Phases

### Phase 1 — Observe

Notice what was rough, surprising, or improvable. Pin down the mechanism in
question (which skill, command, or process) and what specifically happened.
Distinguish a mechanism signal (feedback) from a thinking delta (scenario) — if
it's the latter, hand off to `hivemind-capture`.

### Phase 2 — Draft

Write the feedback entry as a complete markdown document, frontmatter and all,
using the shape below. Keep it concrete: what happened, why it matters, and
whether there's a generalizable claim. It's fine for feedback to be
hypothesis-shaped — say so when it is.

### Phase 3 — Align (optional, lighter than capture)

If the user is present and the feedback is substantive, confirm the framing in a
sentence or two before writing — but feedback is lower-ceremony than scenario
capture, so don't force a full alignment loop. If the user already asked you to
file it, just file it.

### Phase 4 — Route

Write the entry into HiveMind's **Feedback** folder via Operator MCP.

- Project ID: `bMxQv-R9IXHVl8jlACagv`
- Feedback group ID: `c1X2fuiDRd6i7AQfCVm84` — **always reference by ID, never
  by name.** The displayed folder name may be edited; the ID is stable.
- Document name: `<YYYY-MM-DD>-<slug>.md`

Discover the exact MCP tool names from your runtime's tool documentation at the
moment of use; do not assume them. Ensure a live HiveMind admin session first
(re-auth if expired, per the credential layout below).

**If the group ID fails to resolve, the folder was changed — surface this to the
user and STOP.** Do NOT recreate the folder; downstream references to the old ID
would break.

### Phase 5 — Report

After a successful write, report back: the HiveMind path, the slug, and a
one-sentence reminder of the takeaway. Then return to the work the feedback came
from.

## Feedback file shape

The feedback document follows this shape (frontmatter plus the sections below):

```markdown
---
type: feedback
date: <YYYY-MM-DD>
originated_in: [<project>]
slug: <kebab-case-signal>
tags: [<...>]
# optional: proposes, impact, generalization
---

# <Title — the observation in a phrase>

## The observation

[What happened. The mechanism in question and the specific friction or surprise.
Concrete enough that a reader who wasn't there understands it.]

## Why it matters

[The cost or risk if left unaddressed. Who hits it, how often, how much it slows
things down.]

## Generalizable claim (if any)

[If the observation points to something beyond this one instance, name it. If
it's a single-instance hunch, say so — that's fine.]

## Proposes (optional)

[A concrete change, if you have one in mind. Otherwise leave for digest.]

## Status

[e.g. single-instance observation; hypothesis; or validated across N projects.]
```

## Reading the Field Guide

At preflight, read the sibling `./field-guide.md` for HiveMind's destination
IDs, frontmatter shapes, and the feedback/scenario distinction. The Field Guide
is a local snapshot; **the live HiveMind Field Guide document is canonical** —
prefer it when reachable, and fall back to the sibling file otherwise.

## What this skill needs

- **Operator MCP** with HiveMind write scope. Discover the exact tool names from
  your runtime's tool documentation at the moment of use — do not hardcode them
  here.
- **The HiveMind credential** per the Field Guide: look in the local `.operator`
  file, conventionally named `OPERATOR_HIVEMIND_ADMIN_*`. Treat that spelling as
  a local convention and ask the user if it is absent.

## Edge cases

- **Operator auth fails or session expired.** Re-auth if possible. If it still
  fails, keep the draft locally and tell the user — they can file it manually or
  rerun later.
- **Nothing meets the bar.** Empty is the right output. Don't manufacture
  feedback to fill a touchpoint; if nothing was rough or improvable, say so and
  move on.
