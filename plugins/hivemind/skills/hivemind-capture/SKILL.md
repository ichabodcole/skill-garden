---
name: hivemind-capture
description:
  Capture a human↔agent decision or thinking delta that surfaced during
  implementation work as a named scenario in HiveMind (the cross-project
  knowledge base). Use when the user pushes back on the agent's approach, a
  non-obvious decision gets made, or a lens-shift emerges — and there's a
  model-level takeaway worth preserving across projects. Triggers explicitly on
  "capture this scenario", "capture this moment", "this is a scenario worth
  capturing", "add this to HiveMind". Also fires in suggested mode when a
  substantive disagreement is resolved with reasoning — agent proposes and fires
  only if the user agrees. Writes to the HiveMind Scenarios folder via Operator
  MCP. Does NOT handle skill/process feedback (use hivemind-feedback) or
  cross-document synthesis (use hivemind-digest).
---

# HiveMind Capture

A scenario is a well-described **moment** — a human↔agent decision/thinking
delta, a non-obvious judgment call, or a lens-shift — distilled into a named,
reusable takeaway and preserved so it stays legible to future work across the
whole portfolio. This skill does one thing: produce a single clearly-captured
scenario, in alignment with the user, and route it to HiveMind's Scenarios
folder. It does NOT do downstream synthesis (principles, playbooks,
lessons-learned) — those are concerns for `hivemind-digest`, which composes over
the scenarios this skill produces.

## When to use

- **Substantive disagreement resolved through discussion** — agent and user
  diverged, talked it through, reached a shared view. The resolution surfaced a
  working principle worth remembering.
- **Non-obvious decision** — a judgment call was made with reasoning that won't
  be self-evident to a future reader of the work product alone. The reasoning is
  worth preserving alongside the outcome.
- **Lens-shift surfaced** — one party (usually the agent) was using a model the
  other (usually the user) doesn't share; the conversation revealed the actual
  lens to use. Worth capturing so the corrected lens travels.
- **Explicit request** — the user says "capture this scenario," "add this to
  HiveMind," or any obvious variant. Fire without further prompting.

## When NOT to use

- **Stylistic preferences** — "I'd phrase that differently" is not a scenario.
  The bar is _model-level_ difference, not surface wording.
- **One-off corrections** — small factual fixes, typos, narrow edits. Capturing
  these adds noise without adding insight.
- **Already-codified material** — if the lesson is already a known principle the
  agent failed to apply, the right move is to surface that principle, not
  capture a new scenario reiterating it.
- **Subject-specific findings** — observations about a particular project's code
  or content. Those belong in that project's own artifacts, not in
  cross-portfolio scenarios.
- **A skill/tool/process-performance signal** — this skill captures a
  decision/thinking _delta_ (how to _think_). If the observation is instead
  about how a _skill, tool, or process_ performed and how to improve it (how a
  _mechanism_ behaved), that is feedback — use `hivemind-feedback` instead. The
  distinction is by subject, not by maturity.

The bar is high on purpose. A scenario should feel worth re-reading six months
later.

## Two trigger modes

### Explicit invocation

The user said the magic words. Examples:

- "Capture this scenario."
- "Capture this moment."
- "This is a scenario worth capturing."
- "Add this to HiveMind."

Fire the skill. No clarifying questions about whether it's worth capturing — the
user has already opted in.

### Suggested invocation

The agent notices something that meets the bar above and proposes the skill:

> _"This feels like a moment worth capturing as a scenario — there's a delta
> worth preserving here. Want me to?"_

If the user says yes, fire. If no, drop it and continue the original work —
don't re-propose unless something new surfaces.

**Don't fire on soft cues** — "huh," "interesting," "good point" are not
invitations. Wait for the bar to be clearly met.

## Phases

### Phase 1 — Recognize

Confirm the moment meets the bar. Quick internal check, not a user-facing step.
Ask yourself:

- Is there a genuine model-level delta or non-obvious judgment?
- Would a future agent or future-you benefit from this captured at the
  working-understanding level?
- Is the takeaway something more general than the immediate conversation it
  surfaced from?
- Is this a thinking delta (scenario) rather than a mechanism-performance signal
  (feedback)?

If any of those are "no," consider whether the skill should fire at all. In
suggested mode, simply don't propose it. In explicit mode, gently note: _"I can
capture this, but it may be more stylistic than scenario-worthy — still want me
to?"_ and let the user decide.

### Phase 2 — Capture

Gather the raw material from the current conversation:

- **What was happening** — the task or context the conversation was inside of.
  Concrete enough that a reader unfamiliar with the session understands the
  situation.
- **The delta or decision point** — what the agent was assuming or proposing,
  what the user's actual lens or preference turned out to be, where they
  diverged.
- **The resolution** — how it was resolved in this conversation. What was
  changed (or not), and why.
- **The named takeaway** — the distilled observation. Frame it as something a
  future agent could _use_, not just describe. Give it a short title (the slug)
  and a 2–4 sentence statement.

Draft this as a complete markdown document, frontmatter and all. Use the shape
below. Quote concrete things — file paths, exact wording, the proposal that was
rejected, the alternative that landed. If conversation context has been
compacted, be explicit in the draft about what is reconstructed vs. firsthand;
the alignment pass is where reconstruction errors get caught.

### Phase 3 — Distill (align with the user)

Get the user's alignment on the draft before writing it. The point is twofold:
that the scenario is described accurately, and that the named takeaway is sharp
enough.

If **Digestify** is available, send the captured draft through it: the full
draft as the rendered body, with targeted questions at the end —

- `context-accurate` — Does this capture the situation correctly?
- `delta-accurate` — Is the delta named the way you'd name it?
- `takeaway-sharp` — Is the takeaway sharp enough to be useful, or does it need
  to be broader or more specific?
- `slug-good` — Is the proposed slug a good handle for finding this scenario
  later?
- `anything-missing` — Is there context or nuance that should be in here?

If Digestify is not available, do the same alignment in chat: show the draft and
ask the same questions conversationally.

If the user's answers indicate substantial revision is needed, redraft and align
again. Don't force one-shot alignment — the cost of a second round is low; the
cost of a misaligned scenario in HiveMind is durable.

### Phase 4 — Route

After alignment, write the scenario into HiveMind's **Scenarios** folder via
Operator MCP.

- Project ID: `bMxQv-R9IXHVl8jlACagv`
- Scenarios group ID: `9vDJ9VOBqgd0g6FEV0oQQ` — **always reference by ID, never
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
one-sentence reminder of the takeaway. Then return to the original work the
conversation interrupted.

## Scenario file shape

The scenario document follows this shape (frontmatter plus five sections):

```markdown
---
type: scenario
date: <YYYY-MM-DD>
source_project: <project name or label>
slug: <kebab-case-slug>
---

# <Title — short, descriptive of the takeaway>

## Context

[What was happening in the conversation/work when the moment surfaced. 1-3 short
paragraphs. Concrete enough that a reader unfamiliar with the session
understands the situation. Reference specific files, decisions, or framings as
needed.]

## The delta

[The model-level difference that surfaced. Structure as three parts:]

**What was being assumed:** [the implicit model behind the agent's proposal or
the original framing.]

**What the actual lens was:** [the model that turned out to be correct, surfaced
through discussion. Stated affirmatively, not as a correction.]

**Where they diverged:** [the specific point of divergence — often subtle, not a
flat right-vs-wrong but two different optimization targets or framings.]

## The resolution

[What was actually done in this conversation as a result. What changed (or
didn't), and why. Include the changed wording, decision, or artifact if
applicable.]

## Synthesis

[2-4 sentences. The named takeaway from this moment. Frame so a future agent
could use it — not just describe what happened but distill what to do with the
insight. This is the section that makes the scenario portable.]

## Related

[Optional. If this scenario echoes or sharpens something already captured
elsewhere — another HiveMind scenario, a playbook, a known working principle —
point at it. Helps the future digest step find clusters.]
```

## Reading the Field Guide

At preflight, read the sibling `./field-guide.md` for HiveMind's destination
IDs, frontmatter shapes, and slug rules. The Field Guide is a local snapshot of
conventions; **the live HiveMind Field Guide document is canonical** — prefer it
when reachable, and fall back to the sibling file otherwise. The one rule that
always holds: a slug names the **takeaway**, not the situation. A good slug
describes what a future reader will learn (kebab-case, 4–7 words); a bad slug
names the conversation, file, or feature where the moment surfaced.

## What this skill needs

- **Operator MCP** with HiveMind write scope. Discover the exact tool names from
  your runtime's tool documentation at the moment of use — do not hardcode them
  here.
- **The HiveMind credential** per the Field Guide: look in the local `.operator`
  file, conventionally named `OPERATOR_HIVEMIND_ADMIN_*`. Treat that spelling as
  a local convention and ask the user if it is absent.
- **Digestify (optional)** for the Phase 3 alignment pass. If unavailable, align
  in chat.

## Edge cases

- **Operator auth fails or session expired.** Re-auth if possible. If it still
  fails, keep the aligned draft locally (e.g. `/tmp/scenario-<slug>.md`) and
  tell the user — the captured material is still useful, and they can land it
  manually or rerun the route step later.
- **Suggested invocation declined.** Don't push. Drop the proposal and continue.
  Don't re-propose for the same moment.
- **The scenario already exists.** Check before writing. If a recent scenario
  covers the same ground, sharpen the existing one rather than duplicating it.
- **No clear single takeaway.** If the moment seems important but you can't
  articulate the named takeaway, don't force one. Either ask the user to help
  name it during alignment (frame the `takeaway-sharp` question that way) or
  recognize it isn't yet ready for scenario form and surface that.
