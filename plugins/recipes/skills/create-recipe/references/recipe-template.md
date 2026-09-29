# Recipe Template & Writing Guide

Detailed template, writing principles, and examples for creating recipe files
under the umbrella `recipes` skill's `library/`.

---

## Recipe File Structure

A recipe is a plain markdown file (`RECIPE.md`) with **no YAML frontmatter**.
The umbrella `recipes` skill loads recipes on demand based on the user's
explicit request, so individual recipes don't need their own skill metadata or
trigger phrases. Adapt sections based on whether the recipe is
technology-specific or technology-agnostic.

```markdown
# <Recipe Name> Recipe

## Purpose

<2-3 sentences explaining what this recipe builds and why it exists. What
problem does it solve? What's the core value proposition?>

<If technology-agnostic, state that explicitly: "This recipe is
technology-agnostic at the architecture level. The concepts work with any
database and frontend framework.">

## When to Use

- <Scenario 1>
- <Scenario 2>
- <Scenario 3>
- <Scenario 4>

## Technology Stack

<Only for technology-specific recipes. Table format:>

| Layer | Technology | Version |
| ----- | ---------- | ------- |
| ...   | ...        | ...     |

## Architecture Overview

<Explain the core architecture. Use ASCII diagrams for layer relationships or
data flow. Include:>

- Core concepts and mental model
- Key design decisions and WHY they were made
- What this architecture intentionally avoids and why
- Trade-offs acknowledged

## Data Model

<If the recipe involves data persistence:>

- Table/collection schemas with column types and constraints
- Relationships between entities (ASCII diagram)
- Required indexes
- Key invariants that must be maintained

## Service Layer / Core API

<The operations the system supports:>

- Service API surface (method signatures)
- Operation-by-operation logic (numbered steps)
- Error types and when they're thrown
- Transaction boundaries

## Implementation Process

<Phased implementation guide, ordered by dependency:>

### Phase 1: <Foundation>

<Steps with code examples showing the pattern>

### Phase 2: <Core Feature>

<Steps with code examples>

### Phase N: <Optional Extensions>

<Steps with code examples>

<Each phase should end with a "Validate:" step describing how to verify the
phase works correctly.>

## Integration Points

<How this system connects to the rest of the app:>

- Auto-save integration
- AI/automation integration
- Sync/API integration
- UI integration patterns

## Settings / Configuration

<User-configurable options, if applicable:>

| Setting | Type | Default | Purpose |
| ------- | ---- | ------- | ------- |
| ...     | ...  | ...     | ...     |

## Adapting to Different Tech Stacks

<Only for technology-agnostic recipes. Guidance for different databases,
frameworks, platforms.>

## UI Reference

<If the recipe includes an admin UI, dashboard, or management interface, add a
references/ directory with interactive HTML mockup prototypes. See
`references/<feature>-mockup.html` for the clickable prototype.>

## Gotchas & Important Notes

<Hard-won lessons, non-obvious requirements, common mistakes:>

- <Gotcha with explanation>
- <Gotcha with explanation>
```

### Recipe Directory Structure

Recipes that include UI references use this directory structure:

```
plugins/recipes/skills/recipes/library/<recipe-name>/
  RECIPE.md                             — The recipe
  references/                           — Visual references (optional)
    <feature>-mockup.html               — Interactive HTML prototype
```

The `references/` directory is optional — only include it when the recipe
describes a visual interface that benefits from a clickable prototype.

---

## Writing Principles

1. **Lead with concepts, follow with code.** Explain the architecture and WHY
   before showing HOW. Someone reading the recipe should understand the mental
   model before seeing implementation details.

2. **Code examples show patterns, not complete implementations.** Include enough
   code to be unambiguous, but don't reproduce entire source files. Show the
   critical integration points and let the implementer fill in the rest.

3. **Capture the ordering and dependencies.** "X must happen before Y because Z"
   is often the most valuable part of a recipe. Explicit ordering prevents the
   hardest debugging.

4. **Explain trade-offs explicitly.** "We store full content per version (not
   diffs) because..." helps implementers decide if the trade-off fits their
   project.

5. **Include gotchas and hard-won lessons.** The things that aren't in any
   library's docs but you discovered through implementation. These are often the
   highest-value content in a recipe.

6. **Be technology-specific OR technology-agnostic, not both.** If the value is
   in integration glue between specific libraries, name those libraries and
   include version numbers. If the value is in the architecture pattern, keep it
   abstract and add an "Adapting to Different Tech Stacks" section.

7. **Don't include UI component code in the recipe text — use prototypes
   instead.** Describe UI integration points and component responsibilities in
   prose within the RECIPE.md. For recipes with admin UIs or dashboards, create
   interactive HTML prototypes in `references/` using the
   `html-mockup-prototyping` skill. This gives implementing agents a visual
   target without polluting the recipe with framework-specific UI code.

---

## Recipe Types

### Technology-Specific Recipes

These capture how to integrate specific libraries. The value is in the glue
code. Examples:

- "Elysia + BetterAuth API" - How Elysia, BetterAuth, and Drizzle wire together
- "Expo + PowerSync" - How to set up local-first sync in a React Native app
- "Nuxt + Tailwind + shadcn-vue" - How to scaffold a Nuxt app with this UI stack

**Characteristics:**

- Named after the technologies
- Include version numbers
- Include actual config files and setup commands
- Code examples use the specific libraries
- "Adapting" section covers swapping individual components

### Technology-Agnostic Recipes

These capture architectural patterns that work across stacks. The value is in
the design and service API. Examples:

- "Document Versioning" - Linear version history with active version model
- "Soft Delete with Restore" - Deletion pattern with recovery
- "Event-Driven Notifications" - Typed event bus for decoupled side-effects

**Characteristics:**

- Named after the pattern
- No version numbers
- Pseudocode or generic TypeScript for examples
- Schema shown in SQL-like notation (adaptable to any DB)
- "Adapting" section covers different databases, frameworks, platforms

### Hybrid Recipes

Some recipes are partially specific and partially agnostic. For example, a
recipe might describe a technology-agnostic architecture but include specific
integration notes for common tech stacks. Use your judgment on how to balance
these.

---

## Examples of Good vs Bad Recipe Content

**Good - captures integration glue:**

```
BetterAuth's handler is mounted with `.mount(auth.handler)`, NOT `.use()`.
The `.mount()` method gives BetterAuth full control of its route subtree.
Elysia's TypeBox validation and middleware do NOT apply to mounted handlers.
```

**Bad - just restates library docs:**

```
To install BetterAuth, run `bun add better-auth`. Then create an auth
instance with `betterAuth({...})`.
```

**Good - explains architectural decision:**

```
Auto-save does NOT create versions. The active version is updated in-place.
This is intentional - creating a version on every keystroke would produce
thousands of versions. Users explicitly save versions as milestones.
```

**Bad - describes without explaining why:**

```
When the user types, the document content is updated. Versions are created
when the user clicks Save Version.
```

**Good - captures ordering and dependencies:**

```
CRITICAL ORDERING:
1. `dotenv-flow/config` FIRST (loads env vars before anything reads them)
2. CORS before session middleware
3. Session middleware before `.mount()` and routes
4. `.mount(auth.handler)` before your route groups
```

**Bad - lists without ordering context:**

```
You need to set up CORS, session middleware, auth handler, and routes.
```
