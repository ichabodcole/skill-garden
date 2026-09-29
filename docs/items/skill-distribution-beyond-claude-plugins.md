---
type: item
title: How skills reach runtimes other than Claude Code
description:
  openpackage has stalled; find a consistent way to install these skills for
  Codex and other runtimes alongside the Claude plugin marketplace.
status: draft
lifecycle: backlog
id: 01a0ee75-3265-75e1-ad14-7c8fbcf5097f
kind: research
generated: { by: claude-opus-5-5, at: 2026-09-29 }
---

# How skills reach runtimes other than Claude Code

These plugins install through the Claude Code plugin marketplace. In the
repository they came from, `dist/` also carried an openpackage build, meant as
the route to other runtimes, but openpackage has stalled. The build was left
behind when the plugins moved here (a decision of 2026-09-29), so today users on
Codex and other agent runtimes have no consistent way to install them.
project-docs, which still ships its own plugin, wants the same answer.

Moved from project-docs-scaffold-template, where it was filed under the plugin
extraction.

## Definition of done

- [ ] The write-up names the options (other package formats, a plain installer
      script, per-runtime marketplaces), what each supports today, and what each
      costs to maintain beside the Claude marketplace.
- [ ] It recommends one, or says why none is worth it yet, and says whether an
      openpackage build should come back.
