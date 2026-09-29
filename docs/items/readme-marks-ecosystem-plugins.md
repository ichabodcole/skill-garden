---
type: item
title: Mark which plugins need the author's software
description:
  The README lists every plugin alike, so another developer can't tell that
  operator, hivemind and agent-bridge need services they may not have.
status: draft
lifecycle: active
id: 01a0eea3-1598-7305-9575-0fd603f7d958
kind: task
generated: { by: claude-opus-5-5, at: 2026-09-29 }
from: PROJECT_MANIFESTO.md
cycle: 2026-09-foundations
---

# Mark which plugins need the author's software

The root `README.md` lists the five plugins in one table, as if each works
anywhere. Three do little without software a stranger may not have: `operator`
needs an Operator account and API key, `hivemind` needs Operator and a HiveMind
workspace, and `agent-bridge` needs the Agent Bridge server and desktop app.
`toolbox` and `recipes` work for anyone. The manifesto names other developers as
this repository's second audience; they should be able to tell which plugins are
for them before installing one.

## Definition of done

- [ ] The README says, for each plugin, whether it works on its own or what
      service it needs.
- [ ] Each of the three plugins' marketplace descriptions names the service it
      needs.

## Related Documents

- [Project Manifesto](../PROJECT_MANIFESTO.md)
