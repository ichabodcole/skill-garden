# hivemind

A Claude Code plugin for the **cross-project knowledge cycle**: capture what you
learn in one project, refine it, and apply it in the next. HiveMind is the
shared knowledge base that sits _above_ any single project — knowledge flows up
(collect), gets refined (digest), and flows back down (disperse), so the same
problems don't get re-solved from scratch each time.

HiveMind is a _concept_, not a storage product. It happens to be backed by an
[Operator](https://operator.live) MCP workspace today, but the plugin is about
the knowledge loop, not about Operator.

## The four skills

| Skill               | Direction | What it does                                                                                                                               |
| ------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `hivemind-capture`  | collect   | Capture a **scenario** — a human↔agent decision/thinking delta from implementation work — as a named, reusable takeaway.                  |
| `hivemind-feedback` | collect   | File **feedback** — a signal about how a skill/process/mechanism performed, usually from an end-of-run touchpoint — to improve it.         |
| `hivemind-consult`  | disperse  | Pull relevant playbooks/scenarios/feedback into the current project, flag work that violates a known principle, materialize to local docs. |
| `hivemind-digest`   | refine    | Triage accumulated feedback and scenarios, then **propose** promotions into Playbooks or Lessons Learned (review-gated).                   |

**Capture vs. feedback** is by _subject, not maturity_: capture is about how to
_think_ (a decision delta); feedback is about how a _tool performed_ (a process
signal).

## The Field Guide

All four skills read a shared **Field Guide** at preflight — the single source
of truth for document types, frontmatter, the promotion ladder, and the stable
folder ID map. Each skill ships a local snapshot (`field-guide.md`); the
**canonical copy lives in the HiveMind workspace itself** (in the `@operator`
folder), so HiveMind is self-describing. Skills prefer the live copy when
Operator is reachable.

## Requirements

- **Operator MCP** access with a HiveMind-scoped credential. Set it up with the
  `operator-setup` skill from the sibling `operator` plugin. The skills look for
  the credential in the local `.operator` file (conventionally
  `OPERATOR_HIVEMIND_ADMIN_*`) and will ask if it is absent.
- **Digestify** (optional, from the `spellbook` plugin) for the capture alignment
  pass — skills fall back to chat if it is unavailable.

## Installation

```
/plugin marketplace add ichabodcole/skill-garden
/plugin install hivemind@skill-garden
```

## Notes

The plugin is drawn as a standalone unit (rather than folded into the `operator`
plugin) so the knowledge-cycle concept stays cleanly separated from the storage
mechanism — and so it can be extracted into its own marketplace later.
