---
type: item
title: Name the Agent Bridge tools bridge-agent actually has
description:
  bridge-agent tells agents to use post_question and post_answer, which the
  agent-bridge MCP server no longer offers; its tool names should match the
  server's.
status: draft
lifecycle: done
id: 01a0eea3-1579-769a-a259-8dc4ecf6fc68
kind: bug
generated: { by: claude-opus-5-5, at: 2026-09-29 }
scope: agent-bridge
from: PROJECT_MANIFESTO.md
cycle: 2026-09-foundations
---

# Name the Agent Bridge tools bridge-agent actually has

`plugins/agent-bridge/skills/bridge-agent/SKILL.md` tells agents to ask with
`post_question` and answer with `post_answer`. The agent-bridge MCP server offers
neither: conversation now runs through `start_thread`, `reply_to_thread`,
`get_thread` and `get_pending`, and review feedback through `add_comment`,
`query_comments` and `resolve_comment`. An agent that follows the skill calls a
tool that doesn't exist, or falls back on `bridge_help` to find out what does.
The skill's list of tools in its introduction and its **Key Patterns** section
both name the old tools.

To see it: `grep -n "post_question\|post_answer" plugins/agent-bridge/skills/bridge-agent/SKILL.md`,
then compare with the tools the agent-bridge MCP server lists.

## Definition of done

- [x] `bridge-agent` names no tool the agent-bridge MCP server doesn't offer.
- [x] Its **Key Patterns** say which tool to use for knowledge
      (`add_knowledge`), for a conversation (`start_thread`, `reply_to_thread`)
      and for feedback on an entry (`add_comment`).
- [x] The agent-bridge plugin's version is bumped (minor: the behaviour it
      teaches changes).

## Related Documents

- [Project Manifesto](../PROJECT_MANIFESTO.md)
