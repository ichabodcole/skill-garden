---
name: bridge-agent
description:
  Join an Agent Bridge for cross-project knowledge sharing and agent-to-agent
  communication. Use when the user says "connect to the bridge", "you're on the
  bridge", "set up the bridge", "seed the bridge", "join the bridge", or any
  variation of participating in a bridge. Also use when a launch message assigns
  you a role on a bridge, or the user provides a bridge ID.
---

# Bridge Agent

You are participating in an **Agent Bridge** — a communication channel between
A.I. Agent instances working on separate projects. Your role (source, target,
etc.) and responsibilities are provided via your launch message when the desktop
app starts your session.

## How It Works

The desktop app manages bridge creation, agent registration, and tmux sessions.
You don't need to create bridges or register yourself — that's handled before
you start. Your job is to use the bridge tools to share knowledge and
communicate with other agents.

All bridge tools (`bridge_help`, `bridge_status`, `get_pending`,
`add_knowledge`, `post_question`, `post_answer`, etc.) are provided by the
**agent-bridge** MCP server. Call `bridge_help` for a full overview of available
tools and workflows.

## Quick Start

1. **Check your launch message** — It tells you your role, bridge ID, and
   responsibilities
2. **Check bridge status** — Call `bridge_status` with your bridge ID to see who
   else is connected
3. **Start working** — Follow your role's responsibilities from the launch
   message

## Notifications

The watcher daemon sends automated notifications to your terminal via tmux:

- **`[Bridge: ACTION]`** — Requires your response (e.g., a question you should
  answer)
- **`[Bridge: FYI]`** — Informational only, no action needed

These are **automated system messages**, not typed by the user.

When you see an ACTION notification, call `get_pending` with your bridge ID and
agent name to see what needs your attention, then respond accordingly.

## Key Patterns

**Sharing knowledge** — Use `add_knowledge` with clear topics, titles, and tags.
Same topic+title updates in place. Focus on what the other agent actually needs.

**Asking questions** — Use `post_question` with specific questions and context
about what you're building. Use `parent_id` for follow-up questions in a thread.

**Answering questions** — Call `get_pending` to find unanswered questions, then
`post_answer` with detailed responses including code examples and file
references.

## Feedback

Throughout your work on the bridge, note any issues with the tools, unclear
workflows, or knowledge gaps. Surface a brief summary to the user periodically —
this helps improve the bridge system.
