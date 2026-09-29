---
type: item
title: De-duplicate the HiveMind field guide
description:
  field-guide.md is byte-identical in all four hivemind skills, so every change
  to it has to be made four times.
status: draft
lifecycle: backlog
id: 01a0ee75-3280-732c-b583-92c085d5b7aa
kind: chore
generated: { by: claude-opus-5-5, at: 2026-09-29 }
scope: hivemind
---

# De-duplicate the HiveMind field guide

`field-guide.md` is byte-identical in all four hivemind skills
(`plugins/hivemind/skills/*/field-guide.md`). Each skill is loaded on its own,
which is why it has a copy, but every edit has to be made four times and the
copies can drift. Found by project-docs' work-taxonomy skill audit (2026-09),
before the plugin moved here.

## Definition of done

- [ ] The field guide has one source, and each skill still finds it when loaded
      on its own. Or a check fails when the four copies differ.
