# Release Please Recipe

## Purpose

Version a repository and write its changelog from its conventional commits, with
release-please running in GitHub Actions. A merge to `main` makes release-please
open (or update) a release pull request that bumps the version files and the
changelog; merging that pull request tags the release and creates the GitHub
Release. Nothing is published to a registry here: publishing, if the project has
any, runs from the tag.

The recipe gives a single-package default, then says which variation to choose
for each shape of project: where the version lives, pre-1.0 behaviour, which
commits should not release, several packages in one repository, a Claude Code
plugin or a marketplace of plugins, and a `develop`/`main` branch strategy. Its
last section is the traps, each with how to spot it and the fix.

## When to Use

- A new project needs versions and a changelog without anyone bumping them by
  hand.
- A project already versioned by hand moves to release-please mid-history.
- A repository holds several things released on their own: plugins, apps,
  workspace packages.
- A release PR proposed the wrong version, released something it should not
  have, or proposed nothing, and you need to know why.

## Technology Stack

| Layer   | Technology                                                   | Version |
| ------- | ------------------------------------------------------------ | ------- |
| Action  | `googleapis/release-please-action`                           | v4      |
| Engine  | release-please (what the action runs)                        | 17.x    |
| Commits | [Conventional Commits](https://www.conventionalcommits.org/) | 1.0     |

The behaviour described below was read from release-please 17.11.2's source. The
action was renamed from `google-github-actions/release-please-action`; use the
`googleapis/` name.

## Architecture Overview

```
push to main
    ↓
release-please reads main's history back to each package's last release
    ↓
splits the commits by package directory, drops excluded ones
    ↓
any commit the changelog shows? ──no──→ nothing happens
    ↓ yes
opens or updates one release PR: version files + CHANGELOG.md + manifest
    ↓
a person merges the release PR when they want to release
    ↓
next run: tags <component>-v<version> (or v<version>) and creates the GitHub Release
```

Three files carry the setup:

- `release-please-config.json` says what the packages are and how each is
  versioned.
- `.release-please-manifest.json` records each package's current version.
  release-please rewrites it in every release PR; you write it by hand only when
  you add a package.
- `.github/workflows/release-please.yml` runs the action on every push to
  `main`.

**What decides the bump.** `feat` is a minor bump, `fix` and everything else a
patch, and a `!` after the type or a `BREAKING CHANGE:` footer a major. A
`Release-As: x.y.z` footer overrides all of it.

**What decides whether there is a release at all.** A package gets a release PR
only when at least one of its commits since the last release lands in a visible
changelog section. By default `feat`, `fix`, `perf` and `revert` are visible;
`chore`, `docs`, `style`, `refactor`, `test`, `build` and `ci` are hidden. A
hidden-type commit marked breaking is shown, and releases. So a run of `docs:`
and `chore:` commits proposes nothing, which is usually what you want.

**What the release PR is.** It accumulates: every new releasable commit on
`main` updates it. Releasing is a decision a person makes by merging it, not a
side effect of landing work.

## Implementation Process

### Phase 1: The single-package default

Use this for one versioned thing at the repository root. Every later variation
changes the config; the workflow stays the same.

**1. Seed the manifest with the version the project has now.** release-please
treats it as already released and bumps from it.

`.release-please-manifest.json`:

```json
{
  ".": "0.1.0"
}
```

**2. Write the config.** Set `bootstrap-sha` to the last commit whose version
the manifest records: the current `HEAD` of `main`, before the commit that adds
these files. On the first run release-please finds no release tag, and without a
bootstrap SHA it reads the whole history and puts every `feat` and `fix` ever
made into the first release. It reads the commits after the bootstrap SHA, not
the SHA itself.

The SHA must end up in `main`'s history exactly as it is. Don't name a commit on
a feature branch that may be rebased or squashed before it lands: a SHA the walk
never meets is no stop at all. If work lands on `develop` first, see
[Branch strategy](#branch-strategy-work-on-develop-release-from-main) for which
commit to name.

`release-please-config.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "bootstrap-sha": "<HEAD of main before this commit>",
  "include-component-in-tag": false,
  "packages": {
    ".": {
      "release-type": "node",
      "bump-minor-pre-major": true
    }
  }
}
```

`include-component-in-tag: false` makes the tags `v1.2.3`. Leave it out and a
`node` package is tagged `<package.json name>-v1.2.3`. Either works; choose
once, because release-please finds the last release by parsing its tag, and a
changed format loses it (see
[the trap](#changing-the-tag-format-or-a-component-after-a-release)).

`bump-minor-pre-major` matters only below 1.0; see
[Pre-1.0 behaviour](#pre-10-behaviour).

**3. Add the workflow.**

`.github/workflows/release-please.yml`:

```yaml
name: release-please

on:
  push:
    branches:
      - main
  # The push trigger cannot recover a missed run: if a run was blocked, fixing
  # the cause fires nothing. This is the way to re-run it.
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write
  issues: write

jobs:
  release-please:
    runs-on: ubuntu-latest
    steps:
      - uses: googleapis/release-please-action@v4
```

The action reads `release-please-config.json` and
`.release-please-manifest.json` by default, so it needs no `with:` unless the
target branch is not the repository's default branch (see
[Branch strategy](#branch-strategy-work-on-develop-release-from-main)).

**4. Let Actions open pull requests.** In the repository's Settings → Actions →
General → Workflow permissions, choose "Read and write permissions" and tick
"Allow GitHub Actions to create and approve pull requests". Without it the run
fails when it tries to open the release PR.

**5. Keep the formatter off the changelogs.** release-please writes
`CHANGELOG.md` in its own format (`*` bullets, two blank lines before a
section), and rewrites it on every release. If the project checks Markdown
formatting (Prettier, markdownlint) in a gate or pre-commit hook, add each
changelog to its ignore file, or the first merged release PR breaks the gate on
`main`, and on `develop` once it is synced.

**6. Commit the files as `chore:` or `ci:`.** A hidden type, so adopting
release-please cuts no release by itself.

**Dry-run before it lands.** The action reads its config from `main`, so nothing
runs until the config is there. The CLI can run the same logic against a local
clone, reading GitHub only for the repository's releases, tags and pull requests
(a token is needed; nothing is written):

```bash
# A scratch clone whose origin's main is the state to test.
git clone --bare . /tmp/rp-origin.git
git clone /tmp/rp-origin.git /tmp/rp-sim
# In /tmp/rp-sim: check out the branch, add test commits, then
#   git push -f origin HEAD:main
npx release-please@17 release-pr --dry-run --trace \
  --repo-url <owner>/<repo> --token "$(gh auth token)" \
  --target-branch main --local --local-path /tmp/rp-sim
```

It prints each release PR it would open, with the diff of every file it would
change. `--local` runs `git fetch`, `git checkout` and `git reset --hard` in
`--local-path`, so never point it at a clone with work in it. Its commit walk is
local `git log`, not the GitHub API the action uses, so it checks the config,
not GitHub's side.

**Validate:** Push to `main`. The workflow run logs
`No user facing commits found since …` and opens nothing. Land a `fix:` commit
on `main`: a release PR titled `chore(main): release 0.1.1` appears, changing
`package.json`, `CHANGELOG.md` and the manifest. Merge it: the next run creates
tag `v0.1.1` and a GitHub Release.

**Settings you can leave out.** These appear in working configs but restate a
default: `"changelog-path": "CHANGELOG.md"`, `"include-v-in-tag": true`,
`"separate-pull-requests": false` for a single package, a `package-name` equal
to `package.json`'s `name`, and the action's `config-file` and `manifest-file`
inputs when they name the default files.

### Phase 2: Choose the variations

Pick every row that applies. Each links to its config below.

| If the project…                                             | Use                                                                             |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------- |
| has no `package.json`, or its version lives somewhere else  | [`simple` and `extra-files`](#where-the-version-lives)                          |
| also prints its version in a CLI, README or second manifest | [`extra-files` with markers](#where-the-version-lives)                          |
| is below 1.0                                                | [`bump-minor-pre-major`](#pre-10-behaviour)                                     |
| carries subtrees at the root that are versioned separately  | [`exclude-paths`](#commits-that-should-not-release)                             |
| wants `docs:` or another hidden type to release             | [`changelog-sections`](#commits-that-should-not-release)                        |
| holds several things, each released on its own              | [manifest mode, independent packages](#several-packages-released-independently) |
| is a workspace whose apps and packages always ship together | [manifest mode, linked versions](#several-packages-one-version)                 |
| is one Claude Code plugin                                   | [one plugin](#a-claude-code-plugin)                                             |
| is a marketplace of plugins, each versioned on its own      | [one package per plugin](#a-marketplace-one-package-per-plugin)                 |
| lands work on `develop` and releases from `main`            | [branch strategy](#branch-strategy-work-on-develop-release-from-main)           |

#### Where the version lives

`release-type` names the file that holds the version of record:

- `node`: `package.json` (and `package-lock.json` when present).
- `simple`: `version.txt` in the package directory, if the file exists;
  otherwise only `CHANGELOG.md` and the `extra-files`.
- Others (`python`, `rust`, `go`, `maven`, `helm`, `expo`, …): the ecosystem's
  own manifest.

If the version also appears anywhere else, list each file in `extra-files`.
Paths are relative to the package directory; a leading `/` means the repository
root.

```json
{
  "packages": {
    ".": {
      "release-type": "node",
      "extra-files": [
        {
          "type": "json",
          "path": ".claude-plugin/plugin.json",
          "jsonpath": "$.version"
        },
        {
          "type": "yaml",
          "path": "chart/values.yaml",
          "jsonpath": "$.image.tag"
        },
        { "type": "generic", "path": "src/cli.ts" },
        { "type": "generic", "path": "README.md" }
      ]
    }
  }
}
```

- `json`, `yaml` and `toml` entries replace the value at `jsonpath`.
- A `generic` entry rewrites only lines that carry a marker. On one line:

  ```ts
  const VERSION = "1.4.0"; // x-release-please-version
  ```

  ```yaml
  docs_version: "1.4.0" # x-release-please-version
  ```

  For a block, in a README for example:

  ```markdown
  <!-- x-release-please-start-version -->

  bun add github:owner/repo#v1.4.0
  <!-- x-release-please-end -->
  ```

  A marker in a file that `extra-files` does not list does nothing.

If a program reports its own version, prefer reading it from the version of
record at runtime (`package.json`) over a second copy with a marker: a copy is
one more thing to go stale.

**Validate:** After the first release, `git show --stat <release commit>` lists
every file in `extra-files`. See
[An extra file is silently not updated](#an-extra-file-is-silently-not-updated).

#### Pre-1.0 behaviour

```json
"bump-minor-pre-major": true,
"bump-patch-for-minor-pre-major": true
```

- `bump-minor-pre-major`: below 1.0, a breaking change bumps the minor (`0.4.2`
  → `0.5.0`), not the major. Without it, the first `feat!` takes a `0.x` project
  straight to `1.0.0`. Set it on every package that starts below 1.0; it has no
  effect at or above 1.0, so leaving it on is harmless.
- `bump-patch-for-minor-pre-major`: below 1.0, a `feat` bumps the patch. Add it
  only if you want `0.x` minors to mean "breaking".

When the project is ready for 1.0, land a commit with the footer
`Release-As: 1.0.0`.

#### Commits that should not release

**Hidden changelog sections.** Keep the default sections unless there is a
reason not to: `docs`, `chore`, `test`, `refactor`, `style`, `build` and `ci`
commits then propose no release. Type commits by what they change for the user
of the package. If the package is itself documentation (a skill, a template, a
recipe), a change to what it tells the user is `feat` or `fix`, not `docs`;
reserve `docs:` for documentation about the repository.

If `docs:` commits should appear and release, replace the list. The list you
give is the whole list, so restate every type:

```json
"changelog-sections": [
  { "type": "feat", "section": "Features" },
  { "type": "fix", "section": "Bug Fixes" },
  { "type": "perf", "section": "Performance Improvements" },
  { "type": "revert", "section": "Reverts" },
  { "type": "docs", "section": "Documentation" },
  { "type": "chore", "section": "Miscellaneous Chores", "hidden": true },
  { "type": "refactor", "section": "Code Refactoring", "hidden": true },
  { "type": "test", "section": "Tests", "hidden": true },
  { "type": "build", "section": "Build System", "hidden": true },
  { "type": "ci", "section": "Continuous Integration", "hidden": true },
  { "type": "style", "section": "Styles", "hidden": true }
]
```

**`exclude-paths`.** If the root package `.` holds subtrees that ship on their
own (plugins with their own `plugin.json` versions, a build output mirror), list
them. Paths are relative to the repository root.

```json
"packages": {
  ".": {
    "release-type": "node",
    "exclude-paths": ["plugins", "dist"]
  }
}
```

A commit is dropped from the package only when **every** file it touches falls
under an excluded path. A commit that touches `plugins/x/SKILL.md` and
`README.md` still counts. See
[Squashing changes whether commits count](#squashing-changes-whether-commits-count).

In manifest mode a package already ignores commits outside its own directory, so
`exclude-paths` is only needed for a package whose directory contains another's,
which in practice means `.`.

#### Several packages released independently

Manifest mode: one entry per directory, each with its own version, changelog and
tag. Settings at the top level are defaults for every package; a package's own
setting replaces the default (it is not merged, so a package that sets
`extra-files` loses the top-level list).

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "release-type": "node",
  "bootstrap-sha": "<HEAD of main before this commit>",
  "bump-minor-pre-major": true,
  "packages": {
    "packages/core": { "component": "core" },
    "packages/provider-x": { "component": "provider-x" }
  }
}
```

```json
{
  "packages/core": "0.3.0",
  "packages/provider-x": "0.1.0"
}
```

- A commit counts toward every package whose directory it touches. A commit that
  touches only files outside every package (root docs, CI, scripts) releases
  nothing.
- Tags are `<component>-v<version>`. Give every package a `component`: a
  `simple` package's default is its `package-name`, which is empty unless set,
  and packages without one collide.
- All releasable packages share one release PR, titled `chore: release main`.
  For one PR per package, set `"separate-pull-requests": true`.
- Leave `.` out of `packages` unless the root is itself a released thing. If it
  is, give it `exclude-paths` for the package directories.
- A package released with pre-release suffixes (`0.2.0-alpha.1`) needs
  `"versioning": "prerelease"` and `"prerelease-type": "alpha"` to bump within
  the suffix, and `"prerelease": true` to mark its GitHub Releases as
  pre-releases. A suffix in the manifest alone does not configure any of this.

**Adding a package later:** in one commit, add its entry to the config and its
current version to the manifest. The manifest entry is what keeps its first
release from reading all history.

#### Several packages, one version

For a workspace (apps and packages under one product version): every package
gets the same version on every release, and workspace dependency ranges are
updated with it.

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "release-type": "node",
  "bootstrap-sha": "<HEAD of main before this commit>",
  "bump-minor-pre-major": true,
  "group-pull-request-title-pattern": "chore: release v${version}",
  "packages": {
    ".": { "component": "product" },
    "apps/api": { "component": "api" },
    "apps/web": { "component": "web" },
    "packages/shared": { "component": "shared" }
  },
  "plugins": [
    {
      "type": "node-workspace",
      "merge": false,
      "updatePeerDependencies": true
    },
    {
      "type": "linked-versions",
      "groupName": "product",
      "components": ["product", "api", "web", "shared"]
    }
  ]
}
```

The manifest lists every path at the same version. `linked-versions` gives the
group one version; `node-workspace` rewrites the workspace packages' dependency
ranges on each other; `"merge": false` stops it building a second combined PR,
since the linked group already produces one. `group-pull-request-title-pattern`
makes the release PR title show the version.

If the packages ship separately to different consumers, use independent packages
instead: a linked version bumps packages that did not change.

#### A Claude Code plugin

For a repository that is one plugin (with or without a marketplace file at the
root): the root package, and the plugin's `plugin.json` as an extra file. If the
marketplace file shows a version, list it too.

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "bootstrap-sha": "<HEAD of main before this commit>",
  "include-component-in-tag": false,
  "packages": {
    ".": {
      "release-type": "node",
      "extra-files": [
        {
          "type": "json",
          "path": "plugin/.claude-plugin/plugin.json",
          "jsonpath": "$.version"
        },
        {
          "type": "json",
          "path": ".claude-plugin/marketplace.json",
          "jsonpath": "$.metadata.version"
        }
      ]
    }
  }
}
```

Use `simple` instead of `node` if there is no `package.json`. A version the
plugin's CLI prints goes in as a `generic` entry with a marker.

#### A marketplace: one package per plugin

For a repository that holds several plugins under `plugins/<name>/`, each
installed and versioned on its own: one package per plugin directory, no root
package. Each release bumps that plugin's `plugin.json`, writes
`plugins/<name>/CHANGELOG.md`, and tags `<name>-v<version>`.

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "release-type": "simple",
  "bootstrap-sha": "<HEAD of main before this commit>",
  "bump-minor-pre-major": true,
  "extra-files": [
    {
      "type": "json",
      "path": ".claude-plugin/plugin.json",
      "jsonpath": "$.version"
    }
  ],
  "packages": {
    "plugins/alpha": { "component": "alpha" },
    "plugins/beta": { "component": "beta" },
    "plugins/gamma": { "component": "gamma" }
  }
}
```

```json
{
  "plugins/alpha": "2.3.0",
  "plugins/beta": "1.0.0",
  "plugins/gamma": "0.2.0"
}
```

- `simple` with no `version.txt` updates only the changelog and the
  `extra-files`, so `plugin.json` is the version of record. The top-level
  `extra-files` path is relative to each package, so one entry serves every
  plugin.
- Seed each manifest entry from that plugin's `plugin.json` as it is at the
  bootstrap commit. A mismatch means the first release bumps from the manifest's
  number and overwrites the file's.
- Leave `bootstrap-sha` in the config until every plugin has released once.
  release-please walks back to it on every run while any package has no release;
  without it, a plugin that has never released reads the whole history.
- `bump-minor-pre-major` at the top level covers any plugin still below 1.0 and
  does nothing to the rest.
- Keep versions out of the marketplace file's plugin entries. The plugin's own
  `plugin.json` is the one place; a second copy per entry needs a second
  `extra-files` entry per plugin.
- Once this lands, nobody bumps `plugin.json` by hand. A hand bump and a release
  PR bump the same number twice. Say so in `AGENTS.md` (or the project's agent
  guide): the version comes from the commit type, so the commit type is where
  "minor for a behaviour change, patch for a fix" is now decided.
- Scope commits to one plugin where you can. A commit touching two plugins
  counts, with one type, toward both.
- A new plugin: add its package entry and its manifest version in the same
  commit that adds `plugins/<name>/`.

**Validate:** A `feat` commit touching only `plugins/alpha/` gives a release PR
that bumps alpha alone. A `docs:` commit, or any commit touching only files
outside `plugins/`, gives none, even a `fix:`. Check both with the
[dry run](#phase-1-the-single-package-default) before the config reaches `main`,
and again on GitHub after.

#### Branch strategy: work on develop, release from main

Work lands on `develop`; `main` is what users get, and release-please watches
`main` only.

1. Land `develop` on `main` (fast-forward, or a merge PR).
2. release-please opens or updates the release PR against `main`.
3. Merge the release PR when you want to release. It can wait and accumulate.
4. **Bring the release commit back to `develop` straight away:**

   ```bash
   git fetch origin
   git checkout develop
   git merge --ff-only origin/main || git merge origin/main
   git push origin develop
   ```

Until step 4, `develop` has the old versions in its version files and
`CHANGELOG.md`, the next `develop` → `main` cannot fast-forward, and a merge can
conflict in the files the release rewrote. The longer `develop` runs apart from
`main` across a release, the more likely the
[history walk trap](#the-history-walk-stops-at-the-last-release-commit).

**Adopting release-please while `main` is behind `develop`.** Don't set
`bootstrap-sha` to `main`'s `HEAD`. The commits between it and the adoption
would be read as unreleased, and any version already bumped by hand among them
is bumped a second time. Set it to the last commit on `develop` before the
adoption branch (the commit it branched from), and seed the manifest from the
version files as they are there. That commit is already on `develop`, so a
rebase or squash of the adoption branch cannot change it, and it reaches `main`
when `develop` does. A `feat` or `fix` on the adoption branch itself then
releases on the first run, as it should: don't bump its version by hand.

If the repository's default branch on GitHub is `develop`, tell the action which
branch it releases from:

```yaml
- uses: googleapis/release-please-action@v4
  with:
    target-branch: main
```

## Gotchas: Known Traps

### The history walk stops at the last release commit

release-please reads `main`'s history newest-first and stops at the commit that
made the last release. If a long-running `develop` holds commits made before
that release commit, and `develop` is then fast-forwarded (or merged) onto a
`main` that has just cut a patch release, those older commits sit behind the
release commit in that order and are never read. Breaking changes and features
among them are ignored.

- **Spot it:** The release PR proposes a patch (`8.1.2`) when you know the
  landed work includes a `feat` or a breaking change, and its changelog lacks
  entries you can see in `git log <last tag>..main`.
- **Fix:** Land a commit on `main` that touches the package and carries the
  footer `Release-As: <version>`. Put the footer on a visible type (`feat`,
  `fix`) or land it with one: a lone `chore:` commit with `Release-As:` leaves
  the changelog empty, and an empty changelog proposes nothing.
- **In manifest mode:** an empty commit (`--allow-empty`) touches no files and
  counts toward **every** package, so its `Release-As:` sets every package to
  that version. Touch a file in the one package instead.
- **Prevent it:** Sync `develop` with `main` right after each release, and land
  `develop` on `main` soon after a release rather than letting work pile up
  across one.

### Squashing changes whether commits count

A squash merge turns a branch into one commit, with one type, touching every
file the branch touched.

- A branch whose commits each stayed inside an excluded path (`plugins/`) plus
  one `docs:` commit outside it proposes no release when merged commit by
  commit. Squashed as `feat:`, it touches an included path with a releasing type
  and cuts a release.
- In manifest mode, a branch with a `feat` for one plugin and a typo fix in
  another becomes one `feat` for both.
- A `!` or `BREAKING CHANGE:` footer on a branch commit is lost unless the
  squash message carries it.
- **Spot it:** The release PR bumps a package the branch did not mean to
  release, or bumps it by the wrong amount.
- **Fix:** Land branches that mix packages or excluded and included paths by
  merge or fast-forward, so each commit keeps its own files and type. If you
  squash, write the squash message's type and footers for what the branch does
  to each package it touches. To undo a wrong proposal before merging the
  release PR, land a commit with `Release-As:` for the right version.

### The release PR may have no checks

release-please opens and updates its PR with the workflow's `GITHUB_TOKEN`, and
GitHub starts no workflow from an event that token causes. The release PR shows
no checks until a person pushes to it (for example with "Update branch").

- **Spot it:** The release PR has no checks, or a required check waits forever
  on "Expected — waiting for status to be reported".
- **Fix:** Merge on `main`'s checks. The release PR changes only version files,
  changelogs and the manifest, and `main`'s head has already passed. If a branch
  ruleset requires a check, either let the release PR bypass it, or give the
  action a token from a GitHub App (`with: token:`) so its pushes start
  workflows.
- **Related:** After a fix lands on `main` in a hidden-type commit (`test:`),
  release-please may leave the release PR's branch as it was, because its
  changelog did not change. Use "Update branch" on the PR to bring the fix in.

### Tests that pin a version fail on every release

Every release rewrites `package.json`, the manifest and every `extra-files`
entry. A test that pins a version, or compares a generated tree against a
fixture containing one of those files, passes on `develop` and fails on the
release PR or right after it merges.

- **Spot it:** A check fails only on the release PR or on the release commit,
  and the diff it complains about is a version string.
- **Fix:** Derive expected versions from the version of record (read
  `package.json` or the manifest in the test). Exclude the version-bearing files
  from whole-tree fixture comparisons, and test them separately.

### A breaking change was not marked

release-please knows a change is breaking only from `!` or a `BREAKING CHANGE:`
footer. Behaviour that breaks callers in a commit typed `feat:` or `fix:`
releases as a minor or patch.

- **Spot it:** Before merging a release PR, read its notes: a breaking release
  has a `⚠ BREAKING CHANGES` section.
- **Fix:** Land a commit that touches the package, typed with `!` and carrying a
  `BREAKING CHANGE:` footer that says what breaks. The release PR updates to the
  major (or, below 1.0 with `bump-minor-pre-major`, the minor).

### An extra file is silently not updated

An `extra-files` entry whose path does not exist is skipped without an error,
and a `generic` entry in a file with no `x-release-please-version` marker
changes nothing. The file keeps its old version for ever, and nothing reports
it.

- **Spot it:** After a release, a file listed in `extra-files` is missing from
  `git show --stat <release commit>`, or still shows the previous version.
- **Fix:** Correct the path (relative to the package directory) or add the
  marker. For a project with several extra files, add a check to the gate that
  reads `extra-files` from `release-please-config.json` and fails when a path is
  missing, a `generic` file has no marker, or a value differs from the manifest.
  Derive the list from the config rather than restating it.

### The first run releases all of history

With no release tag to find and no `bootstrap-sha`, release-please reads back
through the whole history (up to 500 commits) and proposes a release built from
every `feat` and `fix` ever made. A `bootstrap-sha` that is not in `main`'s
history does the same: it named a commit on a branch that was later rebased or
squashed.

- **Spot it:** The first release PR's changelog runs to hundreds of entries, or
  the version jumps.
- **Fix:** Close the PR, set `bootstrap-sha` to the commit before adoption as it
  is on `main`, make sure the manifest holds the current version, and re-run the
  workflow. `bootstrap-sha` is read on every run while any package has no
  release, so leave it in the config.

### The formatter rejects the generated changelog

release-please writes `CHANGELOG.md` with `*` bullets and two blank lines before
each section. Prettier rewrites both, so a gate that checks Markdown formatting
fails on the release commit.

- **Spot it:** `main`'s checks fail right after a release PR merges, on
  `CHANGELOG.md` alone; or, once `develop` is synced, the pre-commit hook
  refuses every commit.
- **Fix:** Add the changelogs to the formatter's ignore file
  (`plugins/*/CHANGELOG.md` in a marketplace), as
  [step 5](#phase-1-the-single-package-default) does.

### Changing the tag format or a component after a release

release-please finds a package's last release by parsing tags with the package's
`component` and `include-component-in-tag`. Change either after releases exist,
and it no longer recognises its own tags.

- **Spot it:** The run logs
  `Found release tag with component '…', but not configured in manifest`, then
  walks history as if on its first run.
- **Fix:** Put the old setting back. If the change is needed, make sure the
  manifest holds each package's current version and set the top-level
  `last-release-sha` to the last release commit for one run, then remove it.

### A run was missed

If a run failed (read-only workflow permissions are the usual cause), fixing the
cause fires nothing: the push trigger has already passed.

- **Spot it:** Commits are on `main`, there is no release PR, and the last
  workflow run failed.
- **Fix:** Run the workflow from the Actions tab. That is what the
  `workflow_dispatch` trigger in the default workflow is for.
