---
type: item
title: Run the repository's gate in CI
description:
  A GitHub Actions workflow runs on every push and pull request the same gate
  the pre-commit hook runs, so a change that skipped the hook still can't land
  unchecked.
status: draft
lifecycle: active
id: 01a0ee8e-de38-779d-be19-e022934fbea6
kind: task
generated: { by: claude-opus-5-5, at: 2026-09-29 }
blocked_by: [01a0ee8e-de1a-74a4-adc9-ffd5e9b918e8]
cycle: 2026-09-foundations
---

# Run the repository's gate in CI

A pre-commit hook can be skipped (`--no-verify`, or an edit made on GitHub). A
workflow on push and pull request that runs the same gate catches what the hook
didn't: formatting, the docs check, and plugin validation. project-docs' own
`docs-check.yml` is a model. Validating plugins in CI needs the Claude Code CLI
there; find the lightest way to run `claude plugin validate`, or say why it
can't run in CI.

## Definition of done

- [ ] A workflow runs the pre-commit gate's checks on every push and pull
      request, and fails the run when any fails.
- [ ] It doesn't download anything the gate doesn't need.

Depends on [the quality gates](./quality-gates.md), whose gate it runs.
