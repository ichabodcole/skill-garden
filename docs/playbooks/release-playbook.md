---
type: playbook
title: Releasing Plugins Playbook
description:
  Releasing plugins — landing develop on main, checking and merging
  release-please's PR, and syncing develop after.
tags: [plugins, release]
status: stable
generated: { by: claude-opus-5-5, at: 2026-09-29 }
---

# Releasing Plugins Playbook

## Goal

Each plugin with unreleased `feat` or `fix` commits released at the version
those commits call for: a tag, a GitHub Release, its `plugin.json` and
`CHANGELOG.md` updated on `main`, and `develop` level with `main` afterwards. It
applies whenever work on `develop` should reach the marketplace, which serves
`main`. Getting the commit types right happens earlier, in the
[Changing a Plugin Playbook](./change-a-plugin-playbook.md).

Steps marked **Owner only** are done by the repository's owner (the person who
owns the GitHub repository), not an agent. An agent prepares and checks, stops
at those steps, and tells the owner what to do. Every other step, pushing
`develop` in step 7 included, an agent may do.

## Steps

1. **Confirm `develop` is green in CI.** Run `git fetch origin` and
   `gh run list --workflow check --branch develop --limit 3`. The run whose
   commit is `git rev-parse origin/develop` must be `completed` / `success`. If
   it is still running, wait; if it failed, fix it on `develop` first.

2. **Owner only: land `develop` on `main`.** `git push origin develop:main`. It
   must fast-forward. If the push is rejected, `main` has a release commit
   `develop` lacks: do step 7 first, then push again.

3. **Wait for release-please.** The `release-please` workflow runs on the push
   to `main` and opens, or updates, one pull request titled
   `chore: release main`. If no PR appears and the run failed, fix the cause and
   re-run it with `gh workflow run release-please --ref main`: a fixed cause
   fires nothing on its own. If the run succeeded and opened nothing, no plugin
   has a `feat` or `fix` commit since its last release.

4. **Check the PR against what you expect to release.** It lists only the
   plugins with `feat` or `fix` commits since their last release, each with its
   new version and changelog in the PR's description
   (`gh pr view <number> --json body -q .body`). For each plugin, compare:
   - the plugin is one you meant to release;
   - the bump is right: a `feat` is a minor, a `fix` a patch, a `!` or
     `BREAKING CHANGE:` footer a major (a minor below 1.0), and a breaking
     release has a "⚠ BREAKING CHANGES" section in its changelog;
   - the changelog has an entry for each commit you expect.

5. **If a plugin is listed that shouldn't be, or has the wrong bump or missing
   entries**, find the commits release-please read:
   `git log --format='%h %s' <plugin>-v<last version>..origin/main -- plugins/<plugin>`.
   First run `git fetch --tags` and `git tag -l '<plugin>-v*'` to find the
   plugin's last tag. A plugin with no tag has never released (the usual case
   until each plugin's first release): use the `bootstrap-sha` in
   `release-please-config.json` in place of the tag. Then:
   - A commit typed wrongly (a `feat` that should have been a `fix`, a typo fix
     typed `feat`, a commit meant for another plugin) can't be retyped once on
     `main`, and the PR releases every plugin it lists or none. Tell the owner
     which commit it is and what it does to the release; the owner decides
     whether to merge as it is or set the version with `Release-As:` (last
     bullet).
   - A `feat` or breaking change you can see in `git log` that the PR ignores
     means release-please's history walk stopped at the last release commit
     before reaching it. Correct the version with `Release-As:`.
   - To force a version, land on `develop`, then `main` (step 2), a `feat` or
     `fix` commit that changes a file in that plugin only, with the footer
     `Release-As: <x.y.z>`. The release PR updates to that version. Don't use an
     empty commit (`--allow-empty`): it touches no files, so it counts toward
     every plugin and sets them all to that version. Don't use a lone `chore`
     commit either: its changelog is empty and it proposes nothing.

6. **Owner only: merge the release PR.** It shows no CI checks: release-please
   opens it with the workflow's token, and GitHub starts no workflow for that
   token's events. This is expected. The PR changes only versions, changelogs
   and the manifest, and `main`'s head already passed. Merge it on that basis,
   with a merge commit, and don't add a required status check to `main`: the
   release PR would wait on it forever. When it merges, the workflow runs again
   and creates each plugin's tag and GitHub Release.

7. **Sync `develop` with `main` straight away**, so `develop` carries the new
   versions and the next push to `main` fast-forwards:

   ```bash
   git fetch origin
   git checkout develop
   git merge --ff-only origin/main
   git push origin develop
   ```

   If `--ff-only` refuses, `develop` has commits made after step 2. Run
   `git merge origin/main` instead, resolve any conflict in favour of `main`'s
   version files and changelogs, and push.

## Verification

- [ ] `git fetch --tags && git tag -l '<plugin>-v*'` lists `<plugin>-v<version>`
      for each plugin the PR released.
- [ ] `gh release list` shows a release named for each of those tags.
- [ ] For each released plugin, on `develop` after step 7,
      `jq -r .version plugins/<plugin>/.claude-plugin/plugin.json` prints the
      same version as
      `jq -r '."plugins/<plugin>"' .release-please-manifest.json`.
- [ ] `plugins/<plugin>/CHANGELOG.md` has a section for the new version.
- [ ] `git rev-parse origin/main origin/develop` prints the same commit twice
      (or, if step 7 needed a merge, `git log origin/develop..origin/main`
      prints nothing).
- [ ] `gh run list --workflow check --branch main --limit 1` shows the release
      commit's run as `success`.
