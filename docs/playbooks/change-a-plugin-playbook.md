---
type: playbook
title: Changing a Plugin Playbook
description:
  Changing a plugin — adding, changing, removing or renaming a skill, or adding
  a plugin — with the commit type that releases it correctly.
tags: [plugins, release, skills]
status: draft
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
   - Its frontmatter `name` is the skill's folder name.
   - Its `description` names the phrases that should trigger it and what it does
     not do, and which sibling skill does that instead. Match the existing
     skills, for example `plugins/hivemind/skills/hivemind-consult/SKILL.md`:
     "Triggers on …", then "Does NOT … (use …)". Keep triggers narrow; a skill
     should fire when asked, not when guessed.
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
     change `name` to `<new>` and rework the `description`'s trigger phrases for
     the new name. To remove, `git rm -r` the skill's folder, and delete any
     untracked leftover (a `.DS_Store`) so the folder is gone.
   - Scrub live references to the old name:
     `grep -rIwn --exclude=CHANGELOG.md '<old>' plugins/ .claude-plugin/ README.md AGENTS.md docs/PROJECT_MANIFESTO.md`.
     `-w` matches the name as a whole word, so a short name doesn't match inside
     longer ones. Rewrite or remove each hit, including the plugin's `README.md`
     row and `marketplace.json` tags.
   - Leave history alone: the plugins' `CHANGELOG.md` files, `docs/items/`
     (their sessions and write-ups included), and closed cycles in
     `docs/cycles/` record work that happened. Don't rewrite them.
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
   - `plugins/<name>/.claude-plugin/plugin.json` with `name`, `version`,
     `description`, `author`, `homepage`, `repository` and `license: "MIT"`.
     Copy the fields from an existing one, such as
     `plugins/hivemind/.claude-plugin/plugin.json`.
   - `plugins/<name>/skills/`, with at least one skill written as in step 1.
   - An entry in `.claude-plugin/marketplace.json` with `name`, `source`
     (`./plugins/<name>`), `category` and `tags`, and no version.
   - `"plugins/<name>": { "component": "<name>" }` under `packages` in
     `release-please-config.json`, and `"plugins/<name>": "<version>"` in
     `.release-please-manifest.json`, the same version as `plugin.json`. Without
     them release-please never releases the plugin. The commit that adds the
     plugin counts toward its first release, so expect the release PR to propose
     a bump from this version; read the number there (step 4 of the
     [Releasing Plugins Playbook](./release-playbook.md)).
   - A row in the root `README.md`'s plugin table, with its Needs column filled
     ("Nothing extra" if it needs nothing).
   - `<name>` in `lint.scopes` in `.project-docs.json`, so work items can scope
     to it.
   - The plugin in `docs/PROJECT_MANIFESTO.md`'s "What It Does" list, and in
     "Who Is It For?" if it needs the author's software.
   - Type the commit `feat(<name>): …`.

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
   context from yours, and give it the skill you changed (for a removal, each
   dependent you changed) plus the files that skill links to directly. Ask it to
   report, not edit: what is confusing, what could be read more than one way,
   and what it assumes a first-time reader already knows. Decide yourself what
   to act on, and make the changes before committing.

7. **Commit**, with the types the steps above gave, one plugin per commit where
   you can. A commit that touches two plugins counts, with its one type, toward
   both.
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

Run these on your branch after `git fetch origin`.

- [ ] `bun run check` passes.
- [ ] After a removal or rename,
      `grep -rIwn --exclude=CHANGELOG.md '<old>' plugins/ .claude-plugin/ README.md AGENTS.md docs/PROJECT_MANIFESTO.md`
      prints nothing.
- [ ] `git log --format='%h %s%n%b' origin/develop..HEAD -- plugins/<plugin>`
      shows, for each commit, a `feat(<plugin>)` or `fix(<plugin>)` subject
      (with `!` and a `BREAKING CHANGE:` footer for a removal or rename), and no
      `chore`, `docs` or `style` commit that was meant to release. Run it once
      per plugin the branch touched, including dependents.
- [ ] `git diff origin/develop..HEAD -- 'plugins/*/.claude-plugin/plugin.json'`
      shows no change to a `version` line.
- [ ] For a new plugin, `git show --stat <commit>` lists `plugin.json`,
      `marketplace.json`, `release-please-config.json`,
      `.release-please-manifest.json`, `README.md`, `.project-docs.json` and the
      manifesto together, and the manifest's version equals `plugin.json`'s.
- [ ] A cold read ran on each changed skill, and you can say for each point it
      raised whether you changed the skill or chose to leave it.
- [ ] Optional: to see the release PR your commits would produce before they
      reach `main`, run the dry run in the release-please recipe: the bold
      paragraph "Dry-run before it lands", near the end of
      [Phase 1](../../plugins/recipes/skills/recipes/library/release-please/RECIPE.md#phase-1-the-single-package-default).
      Run its commands exactly as given, from this repository's root: they make
      their own scratch clones under `/tmp`, and its `--local-path` must name
      one of those, never a clone with work in it. It needs a GitHub token.
