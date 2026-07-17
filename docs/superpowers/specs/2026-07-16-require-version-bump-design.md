# Require plugin version bump in CI (#84)

**Status:** approved, pre-implementation
**Date:** 2026-07-16
**Issue:** #84 — "a merge without a version bump silently never ships"
**Family:** third and last of the invariant-lint family (#82, #86 done and merged)

## Problem

The Claude plugin cache is keyed by **version string**, not commit:

```
~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/
```

Once `<version>/` exists, `claude plugin update` compares the manifest version to
the directory name, finds them equal, and prints *"already at the latest version
(0.1.0)"* — then never re-fetches. **A content change with an unchanged version
never reaches installed users.** The success message reports on the *version*, not
the *content*, but reads as "you are up to date." This is the family's signature
failure: the absence of a signal reads as a passing signal — here actively worse
than absent, a green checkmark over stale content.

## Invariant to enforce

> If any byte under `plugins/<name>/` changes in a PR, then
> `plugins/<name>/.claude-plugin/plugin.json`'s `version` must differ from its base
> value. Otherwise CI fails **red**.

**The check blocks.** Not a warning. A warning is one more green-ish signal nobody
acts on — the exact disease this family cures.

### Why "ANY byte", not "only shippable files"

The cache is a byte-for-byte mirror of the plugin directory — tests, docs, and
comments are copied too, not just skills/commands/agents. So the true invariant is
simply *dir content differs ⟹ version differs*. Drawing a "docs/tests don't count"
line reintroduces the classification judgment that lets a shippable change get
mislabeled non-shippable — the precise failure mode the family exists to remove. An
unnecessary bump (e.g. for a test-only edit) is cheap and fails safe; a missed bump
is the silent failure being killed. The version-bump commit itself edits
`plugin.json` (which lives under the dir), and that *is* the bump — so the rule never
trips over its own satisfaction.

## Architecture

Four files: three new for the check, plus one edit to close a gap this change would
otherwise open in the family's own safety net (see file 4). The decision logic is
**extracted into a script** so it is testable locally in seconds (fail-first proof)
rather than only via slow CI round-trips, and leaves a permanent regression test. This
mirrors how #82/#86 earned their proof.

```
.github/scripts/require-version-bump.sh     # decision logic (pure, injected inputs)   NEW
.github/workflows/require-version-bump.yml   # thin CI wrapper                          NEW
.github/tests/test-require-version-bump.sh   # fail-first local suite (glob-picked-up)  NEW
.github/tests/test-workflow-globs.sh         # generalized to cover ALL workflows       EDIT
```

### 1. `.github/scripts/require-version-bump.sh`

Dependency-free and **bash-3.2-safe** — the same script runs on the ubuntu workflow
(bash 5), the macos test runner (bash 3.2.57), and the developer's Mac locally. No
associative arrays, no `mapfile`/`readarray`, no globstar. No `jq` (the local Mac may
lack it); the `version` field is parsed with `sed` against our own controlled JSON.
**No git and no jj:** the script reads only plain files — getting the base tree onto disk
is the workflow's job (a second checkout, §2). This is deliberate: it keeps the check
VCS-agnostic and makes the suite (§3) runnable with no VCS at all, so fail-first proof
works even where an agent's shell forbids raw `git` (this repo's jj rail).

**Injected inputs** (this is what makes it testable):

| Input | Source | Meaning |
|---|---|---|
| `CHANGED_FILES` | env, newline-separated repo-relative paths | what the PR touched |
| `BASE_DIR` | env, a directory path | a checkout of the PR's base ref; base versions read from `"$BASE_DIR/<path>"`. A manifest absent there ⟹ plugin is new. |
| head versions | working tree on disk (cwd = repo root) | the PR's proposed content |

**Version parse** (no jq):

```sh
version_of() {
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}
```

**Logic:**

1. Derive the set of changed plugin names:
   `printf '%s\n' "$CHANGED_FILES" | sed -n 's#^plugins/\([^/]*\)/.*#\1#p' | sort -u`
2. For each changed plugin `<name>` (manifest `plugins/<name>/.claude-plugin/plugin.json`):
   - head manifest **missing on disk** → **full deletion → skip**
   - `head_ver` = `version_of < <manifest>`
   - `base_ver` = `version_of < "$BASE_DIR/<manifest>"` if that file exists, else empty
     (base manifest absent → **new plugin → pass**)
   - `base_ver` non-empty **and** `base_ver == head_ver` → **FAIL** (content moved,
     version didn't)
3. Emit one `::error::` line per offending plugin — **name all of them**, not just the
   first. Exit 1 if any failed, else 0.

**The one shell trap this script must avoid** (it is the family's own signature failure —
a silent green over a real problem):

- **The accumulating loop must be a here-string, not a pipe.** Writing `… | sort -u |
  while read name; do … failed=1; done` runs the loop in a **subshell**; `failed` is lost
  and the script exits 0 — a green check over an unbumped change, i.e. #84 reproduced
  inside its own fix. The loop MUST consume the plugin-name list via `<<<` (here-string)
  so the accumulator lives in the main shell, exactly as `test.yml:58` does deliberately.

### 2. `.github/workflows/require-version-bump.yml`

Thin wrapper. **ubuntu-latest** — matches `validate-frontmatter.yml`'s runner choice,
where `gh` and bash 5 are present; sidesteps the bash-3.2 macos trap entirely (the
script is still written 3.2-safe because the *test suite* runs it on macos). The base
tree is materialized by a **second `actions/checkout`** into `./_base`, so the script
never touches git itself.

```yaml
name: Require Version Bump
on:
  pull_request:
    paths:
      - 'plugins/**'
jobs:
  require-version-bump:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4          # PR head into the workspace root
      - uses: actions/checkout@v4          # PR base into ./_base for comparison
        with:
          ref: ${{ github.event.pull_request.base.sha }}
          path: _base
      - name: Require a version bump for any changed plugin
        env:
          GH_TOKEN: ${{ github.token }}
          BASE_DIR: _base
        run: |
          CHANGED_FILES="$(gh pr diff ${{ github.event.pull_request.number }} --name-only)"
          export CHANGED_FILES
          bash .github/scripts/require-version-bump.sh
```

Notes:
- **Two checkouts, head first.** Head lands in the workspace root; base is checked out
  into the `_base` subdir (`path: _base`), which cleans only `_base` and leaves head
  intact. The script then compares `plugins/<name>/…` (head) against
  `_base/plugins/<name>/…` (base) with plain file reads — no `git show`, so no
  `fetch-depth: 0` and none of the `pipefail`/exit-128 fragility a `git show` path carries.
  `_base` is never a false "changed plugin": `CHANGED_FILES` comes from `gh pr diff`, not
  the filesystem.
- `gh pr diff --name-only` is the repo's established way to list PR-changed files, and
  it **includes deleted paths**. Unlike `validate-frontmatter`, this check does *not*
  pre-filter to still-existing files — deletion handling lives per-plugin in the script
  (head-manifest existence), where it can distinguish partial deletion (needs a bump) from
  full deletion (skip).

### 3. `.github/tests/test-require-version-bump.sh`

Fail-first proof, auto-discovered by `test.yml`'s existing
`find plugins .github -path '*/tests/test-*.sh'` glob. **No VCS** — each case builds two
plain directories, a `head/` tree and a `base/` tree, under a temp dir; there is no `git
init`, no commits, and thus no need for a git identity. This is what lets the suite run
even under this repo's jj rail (which blocks raw `git` in-session) and keeps **fixtures
out of real plugin directories**. Written bash-3.2-safe and run with `/bin/bash` (never
interactive zsh — the #90 regression).

Each case writes a `base/` tree and a `head/` tree, sets `CHANGED_FILES` +
`BASE_DIR=<case>/base`, runs the script from `<case>/head`, and asserts the exit code:

| # | Scenario | Expected |
|---|---|---|
| ① | plugin file changed, version **not** bumped | **exit 1** (the red proof) |
| ② | plugin file changed, version bumped | exit 0 |
| ③ | only `.github/` changed | exit 0 (script no-ops) |
| ④ | brand-new plugin (absent in `base/`) | exit 0 |
| ⑤ | full plugin deletion (absent in `head/`) | exit 0 |
| ⑥ | two plugins changed, one bumped one not | exit 1, names the unbumped one |

### 4. `.github/tests/test-workflow-globs.sh` (edit — generalize to all workflows)

This existing #82 lint asserts that every `paths:` glob a workflow gates on matches at
least one file — a dead glob means the workflow silently never triggers, which on GitHub
is indistinguishable from passing (#77). But it currently **hardcodes**
`WF=validate-frontmatter.yml` (line 21) and checks only that one workflow — despite its
own header preaching "EXTRACTED from the workflow, never hardcoded." Adding
`require-version-bump.yml` (gated on `paths: ['plugins/**']`) would introduce a second
`paths:`-gated workflow that this lint does not cover — an unguarded glob shipped inside
the very PR that caps the family. So this change closes that gap.

**Generalization:**
- Iterate `.github/workflows/*.yml` instead of a single hardcoded file.
- For each workflow, extract its `paths:` globs with the existing awk parser. A workflow
  with **no `paths:` block is skipped** — that's legitimate (`test.yml` and
  `close-external-prs.yml` intentionally have none; a lint that demanded globs of them
  would be wrong).
- For each glob found, assert `_glob_match_count > 0` (unchanged logic and the existing
  bash-3.2-safe `find`-based matcher).
- **Backstop preserved:** if **zero** globs are found across *all* workflows, fail loud —
  the parser broke or every `paths:` filter vanished at once (#82 applied to itself). The
  per-workflow "zero globs" case is no longer a failure (many workflows have none); the
  aggregate-zero case still is.
- Per-file messaging: replace the hardcoded `"…from validate-frontmatter.yml"` string
  with the actual filename being checked.

Verified today: `plugins/**` → `_glob_to_findpath` → `*/plugins/*`, and
`find "$ROOT" -path '*/plugins/*'` matches many files, so the new glob is live now — the
lint will pass on it and only fail if `plugins/` is ever renamed/moved without updating
the filter, which is exactly the protection wanted.

## Edge decisions

- **Partial deletion** (remove a skill, keep `plugin.json`) → *requires* a bump; that's
  a shippable change. **Full deletion** → skipped. The precise skip condition is
  "`plugin.json` absent on disk at head," not "entire directory gone" — the two coincide
  for a normal plugin removal, and the degenerate case of deleting only `plugin.json`
  while leaving other files is a broken plugin either way, out of scope to police here.
  Distinguished by per-plugin head-file existence.
- **New plugin** → base version absent → passes; no "bump" is meaningful on first add.
- **Self-application:** this change touches only `.github/` and `docs/` — no
  `plugins/<name>/` — so the check correctly does **not** demand a version bump of
  itself. The fix must not fall into the family it fixes; it doesn't.

## Known out-of-scope risk (documented so it isn't lost)

The `paths: ['plugins/**']` filter interacts with branch protection: if this check is
ever marked **required**, a PR touching only non-plugin files never triggers the
workflow, so the required status never reports and GitHub can block the PR forever
waiting on it. `validate-frontmatter.yml` already carries this exact exposure and it
hasn't bitten. This design matches its behavior rather than diverging. If either check
is made required, both need a companion "always-green on skip" job. Out of scope for
#84.

## Proof plan

1. **Local, fail-first:** `/bin/bash .github/tests/test-require-version-bump.sh` — the
   red case exits red, the green case exits green, edges pass. Behavior proven by
   running, not by reasoning — and because the suite uses no VCS, it runs in-session under
   the jj rail. Both new suites are run with `/bin/bash` explicitly (the #90 regression: a
   green interactive-zsh run went red on CI's `bash`).
2. **Regression, glob-lint:** `/bin/bash .github/tests/test-workflow-globs.sh` after the
   generalization — still green, and now reports checking *both* `validate-frontmatter.yml`
   and `require-version-bump.yml` (proof the new workflow's `plugins/**` glob is covered).
3. **Live end-to-end:** a PR that edits a plugin without a bump turns CI red; adding the
   version bump turns it green. Confirms the workflow wiring (two checkouts, `BASE_DIR`,
   `gh pr diff`) that the local suite injects around, and that `gh pr diff --name-only`
   really does include deleted paths (which cases ⑤ and partial-deletion rely on).
