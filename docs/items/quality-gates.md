---
type: item
title: Set up the quality gates from the zed-biome-husky recipe
description:
  "Standardise formatting and pre-commit checks with the recipes plugin's
  zed-biome-husky-quality-gates recipe: Bun, Biome for code, Prettier for
  Markdown, Zed settings, and a Husky pre-commit gate that also runs the docs
  check and the plugin validator."
status: draft
lifecycle: done
id: 01a0ee8e-de1a-74a4-adc9-ffd5e9b918e8
kind: task
generated: { by: claude-opus-5-5, at: 2026-09-29 }
cycle: 2026-09-foundations
---

# Set up the quality gates from the zed-biome-husky recipe

The repository has no formatter, lint or pre-commit hook: its Markdown isn't
formatted (the README table and `marketplace.json` fail Prettier under
project-docs' config), and nothing stops a commit that breaks the docs gate or a
plugin manifest. Cole wants the tooling standardised with the recipes plugin's
`zed-biome-husky-quality-gates` recipe (in this repository at
`plugins/recipes/skills/recipes/library/`): Bun, Biome as the authority for
code, Prettier for Markdown, Zed editor settings, and Husky with lint-staged.
This also covers the `.prettierrc` the pre-push review suggested. Match
project-docs' Prettier settings so the scaffold's docs format the same way in
both repositories.

## Definition of done

- [x] The recipe is applied: `package.json` with Bun scripts, Biome, Prettier
      for Markdown, Zed settings, and a Husky pre-commit hook through
      lint-staged.
- [x] The pre-commit gate also runs `bun scripts/pdocs/cli.ts check` and
      `claude plugin validate --strict` on the marketplace and each plugin, and
      refuses a commit that fails any of them.
- [x] The existing files pass the gate, formatted in one commit of their own.
