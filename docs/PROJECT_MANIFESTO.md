---
type: manifesto # REQUIRED (OKF §3). Do not change it — the filename decides it.
title: Project Manifesto
description:
  What this project is for, what it deliberately is not, and the principles that
  decide the arguments in between.
tags: [manifesto, principles, scope]
status: stable # OKF §5.4: draft | stable | deprecated. `stable` once it is written.
generated: { by: project-docs-scaffold-template, at: 2026-09-04 }
---

# Project Manifesto

_Last updated: 2026-09-29._

## What Is This?

Skill Garden is a shelf of add-ons for Claude Code, the AI coding assistant.
Each add-on teaches the assistant a skill: how to log into a document editor,
how to build a certain kind of app, how to share what it learned in one project
with the next. The skills here started inside other projects and are useful
beyond them, but are not yet their own thing. They live here, installed from one
place, until they are.

## Who Is It For?

First, its author: a solo developer working across many projects, much of it on
software of their own (Operator, HiveMind, project-docs, Agent Bridge). Some
plugins are specific to that software and do little without it: `operator`,
`hivemind` and `agent-bridge`.

Second, other developers. Some plugins are general, `toolbox` and `recipes`
among them, and anyone who finds one useful is welcome to it.

The skills are shaped by one person's needs working across projects, so they are
rarely about team coordination. That is where they come from, not a boundary: a
team that finds a skill useful should use it.

## Core Principles

- **One marketplace, not ten.** A skill developed in one project that would help
  in others comes here, so there is one place to install it from. A repository
  per skill would be more to maintain than most skills are worth.
- **A playground, while it is one.** Here a skill may be coupled to another
  plugin, to a framework, or to the author's own tools, and the rules about
  references are looser. That freedom is what lets a skill find out what it is.
- **Graduation is felt, not measured.** A plugin leaves when it has become its
  own thing: its purpose has solidified, maintaining it alongside the others has
  started to hurt, and the gravity is plainly elsewhere. There is no threshold.
  project-docs is the precedent: once its vision settled, the plugins it had
  been carrying moved out, and they are here.
- **A plugin graduates to where it belongs.** That may be a repository of its
  own, or the repository of the product it serves: `operator` would move into
  the Operator app's repository once there is enough of it. A plugin that
  belongs to no product, such as `toolbox`, may stay here for good.
- **Each plugin installs on its own.** A skill never reaches into another
  plugin's installed folder. The one exception, `create-recipe`, works in a
  clone of this repository and says so.
- **Every change is versioned.** Each plugin carries its own version, bumped on
  every change: minor for behaviour, patch for typos. The backlog plans to hand
  this to release-please, one changelog per plugin.
- **Skills fire when asked, not when guessed.** Triggers are narrow on purpose:
  `recipes` fires only on the word "recipe", proactive HiveMind skills ask
  before they run, and each description names what it does not do and which
  sibling does.
- **Nothing writes to shared knowledge without a human's approval.** HiveMind
  digests propose and wait. Triage records its decisions as tasks.

## What It Does

- **Connects Claude Code to Operator**: signs in, reuses the session, and
  triages captured Operator documents into a project's docs (`operator`).
- **Carries implementation recipes**: 22 opinionated blueprints for auth, sync,
  desktop and mobile, editors, AI and MCP servers, and tooling, plus a skill
  that extracts a new recipe from a working project (`recipes`).
- **Offers general development tools**: single-file HTML prototypes, Maestro
  mobile tests, and screenshot compression to WebP (`toolbox`).
- **Moves knowledge between projects**: an agent joins an Agent Bridge to trade
  questions with an agent in another project (`agent-bridge`), and HiveMind
  captures, consults, digests and files feedback on a shared knowledge base
  (`hivemind`).

## What It Doesn't Do

- **It doesn't keep a plugin that has become its own thing.** Some plugins may
  stay for good; one with its own gravity leaves.
- **It ships no services.** Operator, the Agent Bridge server and app, and the
  HiveMind workspace live elsewhere. The plugins only teach Claude to use them.
- **It ships no code to run**: no commands, agents, hooks or MCP servers. Every
  plugin is skills and reference files. The only code in the repository is the
  vendored `pdocs` docs CLI, which serves this repository's own docs.
- **It is not a catalogue of other people's skills.** It holds the author's
  skills while they grow.
- **It targets Claude Code only, for now.** Reaching other runtimes such as
  Codex is an open research question, and the openpackage build was dropped in
  the move.

## Design Philosophy

Skills are prose. A skill here is a description tuned to fire at the right
moment and a body that tells an agent what to do, backed by reference files
rather than code. The repository keeps the same discipline for itself: its docs
follow the project-docs scaffold, are created with `pdocs`, and pass
`pdocs check`.

---

## Detective's Notes

### What I noticed

- **The plugins arrived grown.** `toolbox` is at 3.0.0 and `recipes` at 2.3.0.
  The garden received transplants, not seedlings, and the youngest plugin,
  `hivemind` at 0.2.0, is the one with two cleanup chores already filed.
- **Knowledge transfer is the unstated theme.** Recipes carry build knowledge
  between projects, HiveMind carries lessons, Agent Bridge carries questions
  between agents, and `operator-triage` carries captured notes into docs. Most
  of this repository is about moving what was learned in one place to where it
  is needed next.
- **Coupling is a graduation signal.** Because coupling is tolerated here, a
  plugin that must decouple, or that couples ever tighter to one product, is
  telling you where it belongs.

### Tensions and gaps

- **The license is claimed but not granted.** Every `plugin.json` says MIT, but
  the repository has no LICENSE file. `add-a-license` in the backlog covers it.
- **Secondary users can't tell which plugins are for them.** The README lists
  `toolbox` beside `operator` as if both work anywhere. Nothing marks which
  plugins need the author's software.
- **`bridge-agent` has drifted.** Its `SKILL.md` tells agents to use
  `post_question` and `post_answer`. The Agent Bridge MCP server now offers
  `start_thread`, `reply_to_thread` and `add_comment` instead.
- **Two copies of one skill.** `html-mockup-prototyping` exists in both
  `toolbox` and project-docs. A user with both installed has two skills
  competing for the same trigger.

### Questions worth considering

- Should the README mark which plugins need the author's software, so another
  developer knows what will work before installing?
- Should `operator` and `hivemind` graduate together, given that `hivemind`
  signs in through `operator`?
- When a plugin graduates, what happens to users who installed it from here: is
  its entry removed, or pointed at the new home?
