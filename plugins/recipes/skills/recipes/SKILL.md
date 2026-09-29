---
name: recipes
description:
  Index and load implementation recipes — opinionated guides for setting up
  specific tech-stack patterns (BetterAuth APIs, PowerSync sync, Electron IPC,
  Expo voice-to-text, MCP servers, soft delete, document versioning, and more).
  Triggers strictly on the word "recipe" plus context — examples include "use
  the X recipe", "load the X recipe", "what recipes are available", "list
  recipes", "is there a recipe for X", "show me the recipe for X", "implement
  this with the X recipe". Do NOT fire on softer phrasing like "set up X" or
  "add Y" — those stay in chat unless the user explicitly invokes a recipe. When
  triggered, read INDEX.md from this skill folder, match the user's request
  against recipe entries, and load library/<recipe>/RECIPE.md to follow its
  instructions. If the user asks what recipes exist, present the index.
---

# Recipes

The umbrella skill for implementation recipes. Each recipe is a markdown guide
for setting up a specific tech-stack pattern — auth flows, sync systems, IPC
scaffolds, mobile pipelines, etc.

## How to Use This Skill

When a user invokes this skill (by saying "recipe" + some context), do one of
the following:

### "Use the X recipe" / "Load the X recipe" / "Implement this with X"

1. Read `INDEX.md` (sibling of this file) to find the matching recipe.
2. Read `library/<recipe-name>/RECIPE.md` for the full implementation guide.
3. Follow the recipe's instructions. Recipes typically contain a purpose
   section, an architecture overview, the steps to take, and any reference
   materials (mockups, diagrams) under `library/<recipe-name>/references/`.

### "What recipes are available?" / "List recipes" / "Is there a recipe for X?"

1. Read `INDEX.md` and present the list to the user.
2. If they asked about a specific topic, filter to recipes that match.
3. If no recipe matches, say so clearly — don't invent one.

### Adding a new recipe

This skill doesn't add recipes itself — use the **`recipes:create-recipe`**
skill to scaffold a new recipe.

## Layout

```
plugins/recipes/skills/recipes/
  SKILL.md                                # this file
  INDEX.md                                # one entry per recipe
  library/
    <recipe-name>/
      RECIPE.md                           # the implementation guide
      references/                         # optional supporting files
        mockup.html, etc.
```

A recipe is just a markdown file. It does not have its own skill frontmatter and
is not auto-surfaced. The umbrella reads it on demand.

## Why a single skill instead of one skill per recipe

Recipes are reference material consulted on demand, not skills meant to
auto-fire across conversations. Treating each recipe as a skill bloated the
harness's metadata pool and created triggering noise on phrases like "set up X"
or "add Y" — phrases that are too generic to map cleanly to a single recipe. The
umbrella model gives the user explicit, low-collision invocation: say "recipe"
plus a hint, and the agent knows exactly where to look.

## When NOT to fire

Do not auto-fire on these soft cues — they belong in chat unless the user
explicitly invokes a recipe:

- "Set up authentication" → ask which approach; don't assume a recipe.
- "Add a database" → too generic.
- "How do I do X" → answer in chat unless they say "recipe".
- "Build me a [tech] app" → that's not a recipe lookup.

Fire only when the user has used the word "recipe" (or an obvious variant like
"recipes"), or when responding to a follow-up to a previous recipe interaction
in the same conversation.
