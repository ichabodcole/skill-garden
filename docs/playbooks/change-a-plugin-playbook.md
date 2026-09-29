---
type: playbook
title: Changing a Plugin Playbook
description:
  Changing a plugin — adding, changing, removing or renaming a skill, or adding
  a plugin — with the commit type that releases it correctly.
tags: [plugins, release, skills]
status: stable
generated: { by: claude-opus-5-5, at: 2026-09-29 }
---

# Changing a Plugin Playbook

## Goal

A change under `plugins/` that reaches users as the right release: the skill
fires on the phrases it should, nothing live points at a skill that is gone, and
each commit's type and scope make release-please bump the plugin it changed by
the amount the change deserves. It applies to any change to a plugin's files and
to adding a plugin. Releasing what has landed is the
[Releasing Plugins Playbook](./release-playbook.md).

Work on a branch from `develop`. Steps 1 to 5 each say what to change and how to
type the commit; step 7 is where you commit.

## Steps

1. **If you are adding or changing a skill**, edit
   `plugins/<plugin>/skills/<skill>/SKILL.md`:
   - If you write a new skill or change its frontmatter, keep `name` equal to
     the skill's folder name, and make `description` name the phrases that
     should trigger it and what it does not do, and which sibling skill does
     that instead. Match the existing skills, for example
     `plugins/hivemind/skills/hivemind-consult/SKILL.md`: "Triggers on …", then
     "Does NOT … (use …)". Keep triggers narrow; a skill should fire when asked,
     not when guessed.
   - Paths in the skill are relative to its plugin. Don't point into another
     plugin's installed folder.
   - If the plugin has a `README.md` that lists its skills, add or update the
     skill's row there.
   - Type the commit `feat(<plugin>): …` if the change alters what the skill
     does or tells the agent, a new skill included (a minor release). Type it
     `fix(<plugin>): …` if it corrects something, a typo or a wording fix
     included (a patch).

2. **If you are removing or renaming a skill**, treat it as breaking: anyone who
   invoked it by name loses it on upgrade.
   - To rename,
     `git mv plugins/<plugin>/skills/<old> plugins/<plugin>/skills/<new>`, then
     change `name` to `<new>`, rework the `description`'s trigger phrases for
     the new name, and rename the skill's H1 and any mention of `<old>` in its
     body. To remove, `git rm -r` the skill's folder, and delete any untracked
     leftover (a `.DS_Store`) so the folder is gone.
   - Scrub live references to the old name:

     ```bash
     git grep -nIE '(^|[^-[:alnum:]_])<old>($|[^-[:alnum:]_])' -- plugins .claude-plugin README.md AGENTS.md docs ':!docs/items' ':!docs/cycles' ':!**/CHANGELOG.md'
     ```

     The pattern matches `<old>` only where no letter, digit, `_` or `-` sits
     next to it, so `optimize` doesn't match inside `optimize-screenshots` or
     `pre-optimize`. (`grep -w` is not enough: it treats `-` as a word
     boundary.) Rewrite or remove each hit, including the plugin's `README.md`
     row and `marketplace.json` tags.

   - Leave history alone: the plugins' `CHANGELOG.md` files, `docs/items/`
     (their sessions and write-ups included) and `docs/cycles/` record work that
     happened, and the scrub skips them. Don't rewrite them.
   - Fix the dependents in other plugins that the grep found. A skill may name
     another plugin's skill (the `hivemind` skills send the agent to
     `operator-setup`) or its files by path (`create-recipe` in `recipes` copies
     `plugins/toolbox/skills/html-mockup-prototyping/templates/state-flow.html`
     from a clone). Give each dependent plugin a commit of its own, typed
     `fix(<dependent>): …` for a repointed name or path, or
     `feat(<dependent>): …` if its guidance changes.
   - Type the removal or rename `feat(<plugin>)!: …` with a
     `BREAKING CHANGE: <what a user loses or must now call>` footer. This is a
     major release, or a minor while the plugin is below 1.0
     (`bump-minor-pre-major` in `release-please-config.json`; `hivemind` is
     0.x). Check the plugin's current version in
     `.release-please-manifest.json`.

3. **If you are adding a plugin**, make all of these changes, for one commit:
   - `plugins/<name>/.claude-plugin/plugin.json` with `name`,
     `version: "0.0.0"`, `description`, `author`, `homepage`, `repository` and
     `license: "MIT"`. Copy the fields from an existing one, such as
     `plugins/hivemind/.claude-plugin/plugin.json`.
   - `plugins/<name>/skills/`, with at least one skill written as in step 1.
   - An entry at the end of `.claude-plugin/marketplace.json`'s `plugins` list
     with `name`, `source` (`./plugins/<name>`), `category` and `tags`, and no
     version. Reuse a `category` already there if one fits: `development`,
     `documentation`, `communication` or `knowledge`.
   - `"plugins/<name>": { "component": "<name>" }` under `packages` in
     `release-please-config.json`, and `"plugins/<name>": "0.0.0"` in
     `.release-please-manifest.json`. Without them release-please never releases
     the plugin.
   - The footer `Release-As: 0.1.0` on the commit that adds the plugin, so its
     first release is 0.1.0. Without it, release-please releases a plugin seeded
     at 0.0.0 as 1.0.0; seeded at 0.1.0, its first release skips 0.1.0 and is
     0.2.0.
   - A row at the end of the root `README.md`'s plugin table, which follows
     `marketplace.json`'s order, with its Needs column filled ("Nothing extra"
     if it needs nothing).
   - A `plugins/<name>/README.md` only if the plugin needs setup the Needs
     column can't hold (`hivemind`'s is the one there now). It is optional
     otherwise.
   - `<name>` in `lint.scopes` in `.project-docs.json`, so work items can scope
     to it.
   - The plugin in `docs/PROJECT_MANIFESTO.md`'s "What It Does" list, and in
     "Who Is It For?" if it needs the author's software.
   - Type the commit `feat(<name>): …`, with the `Release-As: 0.1.0` footer.

4. **If a skill depends on the author's software** (Operator, HiveMind, Agent
   Bridge, or project-docs' `pdocs` CLI), say so in the plugin's Needs cell in
   the root `README.md` and in the plugin's `plugin.json` `description`, as
   `hivemind`'s does ("Needs Operator and a HiveMind workspace."). Make this
   part of the commit that adds the dependency.

5. **If your change writes a count in prose** ("the four skills", "22 recipes"),
   write around the number instead. If the count must stay, update every place
   that states it in the same commit. When you add or remove a skill, check the
   ones already there: `plugins/hivemind/README.md` has a heading "The four
   skills".

6. **For every change, get a cold read.** Start a fresh agent session with no
   context from yours. Ask it to report, not edit: what is confusing, what could
   be read more than one way, and what it assumes a first-time reader already
   knows.
   - For a small change (a wording fix, a changed step, a repointed path), point
     it at the changed lines and the section they sit in, plus anything those
     lines refer to.
   - For a new or rewritten skill, give it the whole skill plus the files it
     links to directly. For a removal, give it each dependent you changed.
   - Act on findings about your change before committing. For a finding about
     text that was already there, don't widen the change: file it as a work
     item:
     `bun scripts/pdocs/cli.ts new item <slug> --kind task --scope <plugin>`.
   - Note in the commit body (or the pull request description) that a cold read
     ran and what you changed because of it, or "no changes" if nothing.

7. **Commit**, with the types the steps above gave, one plugin per commit where
   you can. A commit that touches two plugins counts, with its one type, toward
   both.
   - Commit each change before starting the next. The pre-commit hook checks the
     working tree, not the commit, so an unstaged or untracked file from another
     change can make a broken commit pass, or a good one fail.
   - Never edit `version` in a `plugin.json` by hand, and don't write version
     history into a plugin's `README.md`. release-please bumps the version and
     writes the plugin's `CHANGELOG.md` when it releases.
   - Don't type a change under `plugins/` as `chore`, `docs` or `style`. Those
     types release nothing, so the change stays unreleased until some later
     commit releases that plugin.
   - Let the pre-commit hook run `bun run check`; never bypass it with
     `--no-verify`. If it fails, fix the cause and commit again.
   - Land the branch on `develop` by a merge or fast-forward (a pull request
     merged with a merge commit is fine), not by squash. A squash gives every
     plugin the branch touched the one type of the squash message, and drops a
     `!` or `BREAKING CHANGE:` footer the message doesn't repeat.

## Verification

Run these on your branch. `$(git merge-base develop HEAD)` is the commit your
branch started from, so the range holds only your branch's commits whether or
not `develop` has been pushed.

- [ ] `bun run check` passes.
- [ ] After a removal or rename, the scrub in step 2 prints nothing:
      `git grep -nIE '(^|[^-[:alnum:]_])<old>($|[^-[:alnum:]_])' -- plugins .claude-plugin README.md AGENTS.md docs ':!docs/items' ':!docs/cycles' ':!**/CHANGELOG.md'`.
- [ ] `git log --format='%h %s%n%b' $(git merge-base develop HEAD)..HEAD -- plugins/<plugin>`
      shows, for each commit, a `feat(<plugin>)` or `fix(<plugin>)` subject
      (with `!` and a `BREAKING CHANGE:` footer for a removal or rename), and no
      `chore`, `docs` or `style` commit that was meant to release. Run it once
      per plugin the branch touched, including dependents.
- [ ] `git diff $(git merge-base develop HEAD)..HEAD -- 'plugins/*/.claude-plugin/plugin.json'`
      shows no changed `version` line in an existing plugin. A new plugin's
      `plugin.json` shows as an added file with `"version": "0.0.0"`.
- [ ] For a new plugin, `git show --stat <commit>` lists `plugin.json`,
      `marketplace.json`, `release-please-config.json`,
      `.release-please-manifest.json`, `README.md`, `.project-docs.json` and the
      manifesto together; `plugin.json` and the manifest both say `0.0.0`; and
      `git log -1 --format=%b <commit>` shows `Release-As: 0.1.0`.
- [ ] Each plugin commit's body, or the pull request description, says a cold
      read ran and what changed because of it. Whether the cold read covered the
      right text can't be checked by a command; a reviewer judges it.
- [ ] Optional: to see the release PR your commits would produce before they
      reach `main`, run the dry run in the release-please recipe: the bold
      paragraph "Dry-run before it lands", near the end of
      [Phase 1](../../plugins/recipes/skills/recipes/library/release-please/RECIPE.md#phase-1-the-single-package-default).
      Run it from this repository's root, naming your branch as the branch to
      test. It makes its scratch clones in a new temporary directory; its
      `--local-path` must name that clone, never a clone with work in it. It
      needs a GitHub token.
