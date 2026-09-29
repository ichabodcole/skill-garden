---
name: html-mockup-prototyping
description: >-
  Trigger on any request to build a mockup, prototype, or rough visual of a UI —
  especially when the goal is design exploration before implementation. Use when
  someone wants to SEE what something could look like: sketching out a flow,
  visualizing multiple UI states (idle/loading/error/success), comparing two
  layout options, or building a clickable preview before writing real code or a
  proposal. Also invoke proactively when reading a proposal, investigation, or
  design resolution that contains complex or undecided UI — suggest a
  prototyping step before locking in an implementation plan. The output is a
  self-contained interactive HTML file, not production code. Do NOT invoke for
  implementing real UI components, adding states to existing code, reviewing
  designs, or answering general UX questions.
---

# HTML Mockup Prototyping

## Overview

Single-file HTML prototypes using Tailwind CDN + Alpine.js. Open in a browser —
no build step, no server, no framework. Best for exploring flows and interaction
states quickly.

**Stack:** Tailwind CSS (utility styling) + Alpine.js (declarative
state/behavior) + Lucide (icons). All load from CDN.

## When to Use

- Design is unclear and needs visual exploration before a proposal or plan
- Feature has multiple states (loading, success, error, empty) that need to be
  shown
- Stakeholder needs to review a flow before implementation begins
- UX patterns are undecided (e.g., single-step vs multi-step upload)

**Not for:**

- Production code or anything that will be committed to the app
- Complex data-driven interactions (use the real UI for that)

## Starter Templates

Two templates are available in `templates/`:

- **`state-flow.html`** — flat single-row switcher. Use for a single flow with
  up to ~7 states (e.g., idle → loading → success → error).
- **`group-state-flow.html`** — two-level group/state switcher. Use when
  covering multiple related flows or tabs in one file (e.g., a multi-tab admin
  UI, all auth flows, or any feature with named sections each having
  sub-states).

Both include the full theme block, CDN imports (Tailwind, Alpine.js, Lucide),
`Alpine.data()` registration pattern, Lucide initialization with debounced
MutationObserver, and a blank content area with placeholder states to replace.

The content area is yours to fill. Sidebar nav, single column, split pane —
whatever the prototype needs.

## Theme Classes

The template provides semantic classes so markup stays readable. Use these
instead of raw Tailwind utility strings:

| Category   | Classes                                                       |
| ---------- | ------------------------------------------------------------- |
| Typography | `page-title`, `section-title`, `label`, `text-body`,          |
|            | `text-muted`, `text-faint`, `text-mono`, `link`               |
| Surfaces   | `card`, `inset`, `panel-section`                              |
| Badges     | `badge-accent`, `badge-muted`, `badge-warning`                |
| Status     | `status-dot-open`, `status-dot-success`                       |
| Buttons    | `btn-primary`, `btn-outline`, `btn-ghost`, `btn-icon`         |
| Forms      | `input`, `select`, `textarea`, `input-error`, `field-error`   |
| Alerts     | `alert-error`, `alert-success`, `alert-info`, `alert-warning` |
| Navigation | `nav-item`, `nav-item-active`, `nav-item-inactive`            |
| Utilities  | `filter-pill`, `skeleton` (loading shimmer)                   |

Add new semantic classes to the theme block as needed — follow the same `@apply`
pattern. Keep raw Tailwind for one-off layout utilities (flex, padding, gap,
etc.).

## Theme Adaptation

Before building, check if the target project has a theme file (CSS variables,
Tailwind config, shadcn theme, etc.). If one exists, ask the user whether the
prototype should reflect the app's look. If yes, adapt the template's theme
block to approximate the app's color palette and general feel.

Keep it lightweight — the goal is visual correspondence, not pixel-perfect
reproduction. Swap the slate palette for the project's colors, adjust accent
colors, match light/dark mode. The semantic class names stay the same; only the
`@apply` definitions change.

**Light theme note:** Adapting to a light theme touches almost every class in
the theme block — it's a near-complete rewrite of all `@apply` definitions, not
just a palette swap. Base colors, surface colors, text colors, borders, and
component states all need adjustment. Plan accordingly, or start from a
light-theme variant rather than modifying the dark default.

## Lucide Icons

[Lucide](https://lucide.dev) provides 1500+ consistent SVG icons via CDN. Use
them for nav items, buttons, status indicators, and anywhere text alone is
ambiguous.

**Usage:** `<i data-lucide="icon-name" class="w-4 h-4"></i>` — the template's
MutationObserver handles initialization, including icons inside `x-show`/`x-if`
blocks.

**Sizing:** `w-3 h-3` (12px), `w-4 h-4` (16px — default), `w-5 h-5` (20px),
`w-6 h-6` (24px).

**Color:** Icons inherit `currentColor` — Tailwind text color classes work
directly.

**Common icons:**

| Category   | Icons                                                            |
| ---------- | ---------------------------------------------------------------- |
| Navigation | `menu`, `x`, `chevron-right`, `chevron-down`, `arrow-left`       |
| Actions    | `plus`, `pencil`, `trash-2`, `download`, `upload`, `search`      |
| Status     | `check`, `check-circle`, `alert-triangle`, `alert-circle`, `x`   |
| Objects    | `file-text`, `folder`, `image`, `link`, `settings`, `user`       |
| UI chrome  | `bell`, `layout-dashboard`, `shield`, `eye`, `eye-off`, `loader` |

Browse all icons at [lucide.dev/icons](https://lucide.dev/icons).

## Flow Design Process

1. **List states first** — write out every distinct screen/state before touching
   HTML (e.g., `idle → analyzing → populated → uploading → success`)
2. **Build the state switcher** — wire up all states even if some are
   placeholders; label each `N · Description`
3. **Fill most important states** — happy path first, then edge cases
4. **Add realistic app chrome** — match the actual context of the page. For
   dashboard/admin flows: sidebar nav + top header. For auth flows, settings
   forms, and onboarding: a plain background + centered card IS the shell. The
   goal is visual context, not always a nav bar.
5. **Review with user** — click through states; iterate on design before
   committing to a plan

## Key Conventions

**State switcher** — Always the amber bar at top. This is what makes it a flow
mockup vs. a static screenshot. For single flows (up to ~7 states), use a flat
button list. For multi-flow mockups with closely related flows, use the
**two-level switcher**:

- Row 1: group tabs (flow names, e.g. "Sign In", "Sign Up", "Account Settings")
- Row 2: state buttons for the active group only
- Groups and states declared as data in `Alpine.data()` — markup stays clean
  with `x-for` and a `get activeGroup()` computed property

```html
<!-- Row 1: group tabs -->
<div class="px-4 pt-2 pb-0 flex items-center gap-1">
  <template x-for="g in groups" :key="g.id">
    <button
      @click="selectGroup(g.id)"
      :class="group === g.id ? 'bg-amber-700/60 text-amber-100 border-amber-600/60' : 'text-amber-400/70 border-transparent hover:text-amber-300 hover:bg-amber-800/30'"
      class="text-xs px-3 py-1.5 rounded-t border border-b-0 font-medium transition-colors"
      x-text="g.label"
    ></button>
  </template>
</div>
<!-- Row 2: state buttons for active group -->
<div class="px-4 py-1.5 flex items-center gap-1.5 bg-amber-900/30">
  <template x-for="s in activeGroup.states" :key="s.id">
    <button
      @click="selectState(s.id)"
      :class="state === s.id ? 'bg-amber-600 text-white border-amber-600' : 'bg-slate-800 text-slate-300 border-slate-600'"
      class="text-xs px-2.5 py-1 rounded border font-medium transition-colors"
      x-text="s.label"
    ></button>
  </template>
</div>
```

See `templates/group-state-flow.html` for a self-contained working starting
point with 3 placeholder groups and 7 states.

**Realistic shell** — Wrap the mockup in app chrome. Avoids "floating widget"
syndrome where design looks good in isolation but context is unclear.

**File location** — Ask the user where they'd like the mockup saved. Common
patterns: project artifacts folder, a `mockups/` directory, or alongside the
feature code. Name the file descriptively (e.g., `upload-flow-mockup.html`).

**Resist real logic** — Buttons should just set `state = 'next'`, not implement
actual behavior. The goal is to show what happens, not make it work.

## Common Mistakes

- **Too many states in one file** — for a single linear flow, keep to ~6-7
  states so reviewers don't get lost. When covering multiple closely related
  flows (e.g., all auth flows), use the two-level switcher to organize them in
  one file — the real constraint is reviewability, not a hard count. Split into
  separate files only when flows are unrelated or the file becomes unwieldy.
- **Missing the state switcher** — without it, reviewers can only see one state.
- **No app chrome** — floating a form on a white page makes layout decisions
  ambiguous.
- **Skipping states** — build all states (including error/empty) early, even as
  placeholders. This is where the most valuable design decisions happen.
- **Lucide + MutationObserver infinite loop** — calling `lucide.createIcons()`
  inside a raw `MutationObserver` callback creates an infinite loop: icons
  modify DOM → observer fires → icons modify DOM again. Always debounce with
  `requestAnimationFrame` as shown in the template.
- **`$watch` in `x-init` for state switcher setup** — using `$watch('state')` to
  auto-configure demo states (e.g., selecting a user when switching to
  "user-selected") causes cascading reactive updates that can freeze the page.
  Instead, put setup logic directly in the state button's `@click` handler:
  `@click="state = 'user-selected'; selectedUser = users[0];"`.
- **`x-if` on table rows** — wrapping `<tr>` elements in `<template x-if>` can
  break table column alignment because the conditional rows render in a separate
  DOM context. Use `x-show` on `<tr>` elements instead — they stay in the same
  table structure and columns align correctly.
- **`x-for` inside `<tbody>`** — placing `<template x-for>` inside `<tbody>`
  causes an `importNode` TypeError. The browser HTML parser strips `<template>`
  tags when nested inside `<tbody>`, giving Alpine a null `template.content`.
  Fix: put the `<tbody>` _inside_ the `x-for` template — `<table>` can have
  multiple `<tbody>` elements. See `references/tables.html` for a working demo.
- **`Object.entries()` destructuring in `x-for`** — using
  `[key, val] in Object.entries(obj)` causes "X is not defined" ReferenceErrors.
  Use `Object.keys(obj)` and access values with `obj[key]` bracket notation. See
  `references/tables.html` for a working demo.
- **SVG/icon pointer events breaking `@click` handlers** — When Lucide replaces
  an `<i>` with an `<svg>`, the SVG and its inner `<path>` elements become real
  DOM nodes that receive pointer events. Clicking directly on the icon means the
  event target is the `<svg>` or `<path>`, not the button. Alpine's handler can
  fail to fire or behave unexpectedly when `.stop` or other modifiers are
  involved. Fix: add `pointer-events-none` to any icon inside a clickable
  element with an Alpine event handler.
  ```html
  <!-- ✅ correct -->
  <button @click="doSomething()">
    <i data-lucide="trash-2" class="w-4 h-4 pointer-events-none"></i>
  </button>
  ```
  This applies to buttons, list items, dropdown triggers, or any interactive
  element where you're relying on the parent to handle the click.
- **`overflow-hidden` clipping dropdowns and tooltips** — the `.card` class
  includes `overflow-hidden` which clips absolutely-positioned children like
  dropdown menus, custom selects, and tooltips. Use `!overflow-visible` on cards
  that contain these components, or move the popover element outside the card
  container.
- **Inline `x-data` with complex state** — large inline `x-data` objects cause
  Alpine.js parsing errors. Always use the `Alpine.data()` registration pattern
  in the template's script block.

## Pattern References

Runnable mini-mockups demonstrating solutions to specific Alpine.js / HTML
problems. See `references/index.md` for the full list.

| Pattern                                           | File                              |
| ------------------------------------------------- | --------------------------------- |
| Tables with `x-for` / `Object.keys`               | `references/tables.html`          |
| Two-level group/state switcher                    | `templates/group-state-flow.html` |
| UI components (toggle, switch, modal, tags, etc.) | `references/components.html`      |

## Skill Feedback

If anything in this skill was unclear, didn't work as expected, or could be
improved, write a `skill_feedback.md` file alongside the mockup output. Keep it
brief — a sentence or two is enough. Only do this if you have something
genuinely useful to report; don't force it.

```
## Skill Feedback
- [What was confusing or broken]
- [What would have helped]
```

This helps the skill evolve based on real usage.
