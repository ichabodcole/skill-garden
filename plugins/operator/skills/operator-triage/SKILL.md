---
name: operator-triage
description: >
  Review Operator documents and route them into a project's docs: most become
  work items filed in `triage` with their Operator source recorded (a task, bug,
  chore or research question), a clear feature idea becomes a feature, a solved
  problem becomes a step appended to a playbook. For each document it assesses
  type, maturity, and clarity, decides the route via the docs decision
  framework, and records the decision as a task to execute. Use when the user
  wants to process, review, sort, or triage a batch of Operator captures (bugs,
  fragments, on-deck, etc.) and turn them into actionable docs or work. Triggers
  when the user says "triage my Operator docs", "process the Operator inbox",
  "review what's in Operator", "sort my fragments", "route these Operator
  items", or wants to clear an Operator capture folder. Requires Operator access
  — depends on the operator-setup skill.
---

# Operator Document Triage

Methodical workflow for reviewing Operator documents and deciding their next
steps in the development pipeline.

## When to Use

Activate when:

- User mentions "triage" with Operator documents
- User wants to review items in Operator folders (bugs, fragments, on-deck,
  etc.)
- User asks to process or route Operator documents
- User has multiple documents to assess and route

## Prerequisites

- Operator MCP access configured (see `operator-setup` skill)
- Valid session with Operator Editor

## Triage Workflow

### 1. Authenticate with Operator

Use the cached session from `.operator` file, or re-authenticate if expired.

### 2. Locate Documents to Triage

Either:

- User provides specific document name(s)
- Browse a folder (e.g., "bugs", "fragments", "on-deck")
- Search for documents matching criteria

### 3. For Each Document: Assess → Decide → Record

#### A. Read and Assess

Read the document and determine:

| Aspect       | Questions                                                |
| ------------ | -------------------------------------------------------- |
| **Type**     | Bug report? Feature idea? Architecture thought? UX flow? |
| **Maturity** | Raw capture? Explored concept? Clear specification?      |
| **Clarity**  | Ready to act on? Needs investigation first?              |

#### B. Decide Routing

**Reference the docs framework:** See `docs/README.md` in the target project for
the decision flowchart and document type definitions. `pdocs` below means
`bun scripts/pdocs/cli.ts` in the target project.

**Intake files work items.** Almost everything that comes in from Operator lands
as a **work item in `triage`**, whatever it will become: the user decides at
triage (the project-docs `triage-items` skill) whether to take it on. Every item
you file **records where it came from** in `source:`, as
`operator:<document id>`, so the capture can be found again.

**Operator → Docs Routing:**

| Operator Content              | Routes To                                                          |
| ----------------------------- | ------------------------------------------------------------------ |
| Bug reports                   | → Work item, `kind: bug`                                           |
| Small feature ideas, chores   | → Work item, `kind: task` or `chore`                               |
| Open questions                | → Work item, `kind: research` (an investigation)                   |
| A clear, wanted feature idea  | → Feature (`backlog`), when the user already wants it              |
| A solved problem, a technique | → A Step and a Verification appended to the playbook for that work |
| Architecture thoughts         | → Architecture documentation                                       |
| UX flow thoughts              | → Interaction Design documentation                                 |
| Work context                  | → Referenced in Sessions                                           |

**Decision Framework** (simplified):

```
Is it a solved problem or a reusable technique?
  → Playbook (append a Step and a Verification to the playbook for that kind
    of work; `pdocs find --type playbook`)

Is it a clear feature idea the user already wants?
  → Feature (`pdocs new feature`, starts in `backlog`)

Is it a question that needs research before anyone commits?
  → Work item, kind: research

Is it anything else worth doing — a bug, a task, a chore, a rough idea?
  → Work item in `triage`

Not worth keeping?
  → Leave it in Operator (or its archive); file nothing
```

**Quick Actions:**

| Route         | Next Action                                                                                                       |
| ------------- | ----------------------------------------------------------------------------------------------------------------- |
| **Work item** | `pdocs new item <slug> --kind <task\|bug\|chore\|research> --source operator:<id> --title "…" --description "…"`  |
| **Feature**   | `pdocs new feature <slug> --title "…" --description "…"`, then the `proposal-writer` agent or `generate-proposal` |
| **Playbook**  | Append a Step and a Verification to the matching playbook; `pdocs new playbook <slug>` only if none fits          |
| **Research**  | File the `research` item as above; launch the `investigator` agent when the user wants it researched now          |
| **Defer**     | Leave it in Operator; note the reason                                                                             |

A work item starts in `triage` — the CLI's default. **Don't pass `--lifecycle`,
and don't set `priority`**: accepting and prioritising it is the user's decision
at triage, not intake's. Write its body and definition of done from the capture.

#### C. Record Decision as Task

Create a task capturing:

- **Subject**: `Triage: <document-name> → <routing-decision>`
- **Description**:
  - Source location in Operator
  - Summary of content (2-3 sentences)
  - Routing decision and rationale
  - Specific next steps to execute

Example:

```
Subject: Triage: missing-feature.md → Work item (research)

Description:
**Source:** Operator/bugs/missing-feature.md

**Summary:**
- Reports that X doesn't work when Y
- Unclear if bug or missing feature
- Needs codebase exploration

**Decision:** Work item, kind: research

**Next Steps:**
1. `pdocs new item missing-feature --kind research --source operator:<id>`
2. Move the Operator document to on-deck
3. Leave the item in `triage` for the user
```

### 4. After Triaging All Documents

1. Run `TaskList` to show all pending triage decisions
2. Ask user if ready to execute decisions
3. Execute in order:
   - File the work items and features in the target project with `pdocs`, and
     append the playbook steps
   - Move documents to appropriate Operator folders
   - Launch agents only where the user asked for the work to start now
4. Run `pdocs check` in the target project, then list what was filed
   (`pdocs find --type item --lifecycle triage`) so the user knows what waits
   for triage
5. Mark tasks completed as each is executed

## Folder Conventions in Operator

| Folder      | Purpose                                               |
| ----------- | ----------------------------------------------------- |
| `fragments` | Raw ideas, quick captures, incomplete thoughts        |
| `bugs`      | Bug reports, issues to investigate                    |
| `on-deck`   | Ready for next action (investigation, proposal, etc.) |
| `proposals` | Feature proposals awaiting approval                   |
| `archive`   | Completed or declined items                           |

## Tips

- **Batch similar items**: If multiple docs route the same way, note patterns
- **Flag dependencies**: If doc A depends on doc B, note in task description
- **Preserve context**: Include enough detail in task to execute later without
  re-reading
- **Ask when unclear**: If routing isn't obvious, ask user for guidance
- **Reference the framework**: When uncertain, consult the `docs/README.md`
  decision flowchart
- **Intake is not triage**: filing an item records it; the user accepts, drops
  and prioritises it later, through `triage-items`
