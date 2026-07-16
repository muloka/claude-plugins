# Kaisen: Breaking the Command/Skill Collision, Repairing Script Paths, and Renaming Fan-Flames

**Date:** 2026-07-15
**Status:** Approved, pending implementation
**Supersedes naming from:** `docs/specs/2026-03-18-permission-gateway-and-fan-flames-design.md`

## Summary

Three defects in `workspace-jj` must be fixed together, because each masks the next. While
fixing them, rename the skill from `fan-flames` to `kaisen`.

| | Defect | Status before this work |
|---|---|---|
| A | Flat `skills/<name>.md` layout — skill never loads | Fixed in #81 |
| B | Command and skill both named `fan-flames` — command shadows skill | Open |
| C | `../scripts/` paths broken by A's fix | Open, **shipped in 0.1.1** |
| D | CI validator exits 2 (`ENOENT`) on any PR that **deletes** an agent/skill/command `.md` | Open, pre-existing, blocks this PR |

**B and C cannot ship separately.** C is currently invisible *because* B keeps the skill
unreachable. Fixing B alone would make the skill load for the first time and then immediately
fail to find its scripts — turning a dormant bug into a live one.

**D blocks the PR mechanically.** This change deletes `commands/fan-flames.md` and
`skills/fan-flames/SKILL.md`; both match CI's filter and would be handed to a validator that
`readFile`s them. Without D's fix, CI fails on a correct change and blames the file we meant to
delete.

## The three defects

### B: the command/skill collision

Commands and skills share one namespace. `workspace-jj` declares both:

- `commands/fan-flames.md` → `workspace-jj:fan-flames`
- `skills/fan-flames/SKILL.md` (`name: fan-flames`) → `workspace-jj:fan-flames`

The command wins. Verified empirically: invoking `Skill(workspace-jj:fan-flames)` returns the
command's text verbatim. That command's entire body says *"Invoke the `workspace-jj:fan-flames`
skill and follow it exactly"* — an instruction that resolves back to itself. The skill is
unreachable.

`peer-review-jj` does not have this problem because its command (`peer-review`) and its skills
(`requesting-change-review`, `receiving-change-review`) have distinct names. That is the
working pattern, and it works by luck of naming rather than design.

**This explains the plugin's entire history.** `/fan-flames` has always worked because the model
hits the loop, abandons the Skill tool, and reads the skill file directly from disk. That is
why stale *cache* content has been observed changing fan-flames' behaviour even though the skill
was never registered: the file was always being **read**, never **loaded**.

### C: the broken script paths (a regression from #81)

The skill documents its own convention:

> `(Script paths are relative to this skill file's directory.)`

- Before #81: `skills/fan-flames.md` → dir is `skills/` → `../scripts/` = `workspace-jj/scripts/` ✅
- After #81: `skills/fan-flames/SKILL.md` → dir is `skills/fan-flames/` → `../scripts/` =
  `skills/scripts/` ❌ — a directory that does not exist

Six sites are affected (SKILL.md lines 93, 170, 201, 322, 324, 473). All six are live in the
shipped `0.1.1` cache.

Nothing caught it: the tests exercise the scripts directly rather than the skill's references to
them, CI validates frontmatter and not path integrity, and the collision meant the paths were
never executed.

### D: CI cannot survive a deletion

`.github/workflows/validate-frontmatter.yml` selects files with `gh pr diff --name-only`, filters
them by path pattern, and pipes the result to `xargs bun validate-frontmatter.ts`. The validator's
`detectFileType` matches on the **path string only** — it never checks existence — so a deleted
path is classified, pushed onto the work list, and handed to `readFile`.

Reproduced (2026-07-15):

```
$ bun .github/scripts/validate-frontmatter.ts plugins/workspace-jj/skills/gone/SKILL.md
Validating 1 frontmatter files...
Fatal error: ENOENT: no such file or directory, open '.../skills/gone/SKILL.md'
$ echo $?
2
```

Pre-existing since the workflow was written. Never hit, because no PR has yet deleted an agent,
skill, or command file — **this one is the first**, and it deletes two.

**Fix: filter the selection to paths that still exist**, in the workflow, before the validator
sees them. The `pull_request` checkout contains the PR's tree, so "the file exists on disk" is
exactly the question "does this file survive the PR".

```bash
FILES=$(gh pr diff "$PR" --name-only \
  | grep -E '(agents/.*\.md|skills/.*/SKILL\.md|commands/.*\.md)$' \
  | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done)
```

Verified end-to-end: the same input that exited 2 now exits 0 and validates the surviving file.

**Rejected — `gh pr diff --diff-filter=d`.** `gh pr diff` does not support `--diff-filter`; its
only flags are `--color`, `--exclude`, `--name-only`, `--patch`, `--web` (verified against
`gh pr diff --help`). This was the obvious fix and it does not exist.

**Rejected — make the validator skip missing files.** That would let a typo'd path pass silently,
which is the same "green by checking nothing" failure this repo has hit three times (#82, #84, the
template hash). Keep the validator strict and fix the *selection*: the workflow is the component
that knows which files are in scope.

## Decisions

### Name: `kaisen`

`workspace-jj` wraps jj — Jujutsu. `workspace-jj:kaisen` therefore reads as *Jujutsu Kaisen*
without contrivance: the pun is a property of the tool being wrapped, not a joke imposed on it.

Rejected alternatives:

- **`shikigami`** (conjured spirits doing parallel work) — more descriptive of the mechanism, and
  a genuinely close second. Forgoes the jj pun.
- **`uzumaki`, `kyoshiki`** — describe aggregation only; they name the FAN IN half. Better suited
  as phase names than as the skill name.
- **`domain-expansion`** — maps well onto isolated workspaces, but names the isolation rather
  than the orchestration.
- **Keeping `fan-flames`** — defensible; it encodes FAN OUT 🪭 + FAN IN 🔥. Not chosen because
  the collision fix opened the question and `kaisen` is a better fit for the same cost.

**Phase names stay literal** (`FAN OUT 🪭`, `FAN IN 🔥`). The skill body is read by agents, not
humans; obscure names there add ambiguity to instructions that must be followed precisely. Fun
belongs in the name you type, clarity in the body it loads.

### Architecture: delete the wrapper

`commands/fan-flames.md` is a six-line wrapper whose only job is to invoke the skill — the
instruction that now loops. Deleting it fixes the collision, removes a redundant layer, and lets
the skill own the name outright.

**Cost:** `argument-hint` and `allowed-tools` are command-only fields. `argument-hint` appears
three times in `plugins/` — `peer-review-jj/commands/peer-review.md`,
`permission-gateway/commands/tune.md`, and the doomed `workspace-jj/commands/fan-flames.md` — all
commands, zero skills. The flags are already documented in the skill's Flags table, so the loss is
the inline UI hint only.

The command's jj-safety preamble ("no raw git, ever") carries real value and **moves into the
skill body** rather than being dropped.

### Path repair: `../../scripts/`

Fix the depth, keep the documented convention.

**Why skill-relative works, with evidence.** The Skill tool announces the skill's own location on
every load — `Base directory for this skill: <absolute path>` — directly observed loading
`superpowers:brainstorming` and `superpowers:receiving-code-review` on 2026-07-15. A loaded skill
therefore knows its own directory, which is exactly what the convention requires. From
`skills/kaisen/`, `../../scripts/` resolves to `workspace-jj/scripts/`.

**Why not `${CLAUDE_PLUGIN_ROOT}/scripts/`.** It is genuinely used in model-facing bash, not only
hooks (`agent-helpers-jj/commands/agent-helpers-setup.md:26`), so the hook/skill asymmetry
originally cited for rejecting it does not exist. But the variable is **unset in the Bash tool's
environment** (tested directly, 2026-07-15) — it appears to be substituted into command bodies
rather than exported to the shell, and whether that substitution happens for *skill* bodies is
unverified. Between two options, the one with direct positive evidence wins.

This decision rests on an observed mechanism, not an assumption. If the Skill tool ever stops
announcing the base directory, this convention breaks silently — which is why C is proved at
runtime (below) rather than by a static file-existence check.

## Change inventory

| Action | Path |
|---|---|
| delete | `plugins/workspace-jj/commands/fan-flames.md` |
| move | `skills/fan-flames/` → `skills/kaisen/` (SKILL.md + wave-reviewer.md) |
| move | `scripts/fan-flames-artifacts` → `scripts/kaisen-artifacts` |
| move **+ edit** | `scripts/fan-flames-task-brief` → `scripts/kaisen-task-brief` — line 31 resolves its sibling by name (`$(dirname "$0")/fan-flames-artifacts`); a pure move leaves it calling a script that no longer exists |
| move | `tests/test-fan-flames-scripts.sh` → `tests/test-kaisen-scripts.sh` |
| edit | `workspace-jj/README.md:107` — retarget the design-spec link; its current target's *filename* contains `fan-flames` and `docs/` is frozen, so gate 6 is otherwise unsatisfiable |
| edit | `skills/kaisen/SKILL.md` — `name: kaisen`; the 6 script paths → `../../scripts/kaisen-*`; absorb the deleted command's jj-safety preamble; every in-body mention of "fan-flames" as the tool's name (e.g. "fan-flames' Parallelism Threshold") → "kaisen"; the `./wave-reviewer.md` template pointer is unchanged (same directory) |
| edit | `tests/test-kaisen-scripts.sh` — script names |
| edit | `tests/test-model-selection-lint.sh` — comment |
| edit | `plugins/permission-gateway/tests/test-permission-gate.sh` — comment path |
| edit | `plugins/workspace-jj/README.md` |
| edit | `CLAUDE.md` — superpowers override table |
| edit | `.github/workflows/validate-frontmatter.yml` — defect D: filter the selection to files that exist |
| create | `plugins/workspace-jj/tests/test-skill-paths.sh` |
| untouched | `docs/plans/`, `docs/specs/` — historical records of past state |

### Cross-plugin references

The name reaches beyond `workspace-jj`. One of these is functional; the rest are comments.

| Path | Kind | Why |
|---|---|---|
| `project-setup-jj/templates/CLAUDE.md.template:15` | **functional** | The superpowers override table, **installed into user projects** by `/project-setup`. Left stale, every project bootstrapped after the rename routes `subagent-driven-development` to a dead skill name. |
| `project-setup-jj/templates/CLAUDE.md.template:1` | **functional, load-bearing** | The `hash:` marker. See below — editing line 15 without changing this line means the fix reaches nobody. |
| `permission-gateway/scripts/permission-gate.sh:515` | comment | narrative about which workflows run `jj op restore` |
| `permission-gateway/tests/test-permission-gate.sh:274` | comment | same, plus a path pointer |
| `project-setup-jj/scripts/jj-workspace-create.sh:21` | comment | "the fan-out pattern fan-flames expects" |
| `workspace-jj/scripts/jj-workspace-create.sh:21` | comment | duplicate of the above |
| `agent-helpers-jj/scripts/jj-agent-helpers.sh:37` | comment | "for a fan-flames ledger start-op" |
| `agent-helpers-jj/README.md`, `project-setup-jj/README.md`, `permission-gateway/README.md` | docs | prose mentions |

### The template hash: a third "no bump, no ship" layer

`templates/CLAUDE.md.template:1` opens with `<!-- jj-project-setup:start hash:f2f52fd2 -->`.
`commands/project-setup.md:176` extracts the hash from the **installed** marker in a project's
CLAUDE.md and compares it to the **template's** hash. Equal ⇒ *"CLAUDE.md already up to date"* ⇒
skip.

**So editing line 15 without changing line 1 means the fix reaches nobody.** Every project already
bootstrapped keeps routing `subagent-driven-development` to a dead skill name, and `/project-setup`
cheerfully reports success. This is #84's lesson one layer down: **the template is keyed by hash —
no rehash, no update.**

**The hash is unreproducible.** It is documented at `project-setup.md:171` as "a content hash …
for version tracking", and `allowed-tools` permits `Bash(md5:*)`. But no script computes it, and
it does not match any obvious md5 of the template (2026-07-15):

| Candidate | Result |
|---|---|
| whole file | `aecf487d` |
| minus marker lines | `3467b252` |
| body between markers | `3467b252` |
| marker line zeroed | `e93f61e3` |
| **actual** | **`f2f52fd2`** |

It is therefore not a content hash but an unverifiable nonce, hand-written once. The update logic
only asks *"do they differ?"*, so **any new value works.**

**Requirement for this plan:** change the hash whenever the template body changes. Compute the new
value as `md5` of the template body *between* the markers, exclusive, first 8 hex chars — the
`3467b252` recipe above — and record the recipe in the template as a comment so the next editor can
reproduce it. This replaces an unverifiable nonce with a real, checkable content hash at no extra
cost, since the value must change regardless.

**Follow-up (out of scope, file separately):** nothing enforces that the hash matches the content.
A future editor can change the template and forget the marker, and `/project-setup` will silently
skip the update forever. That is the same silent-gap class as #82 (a glob matching zero files
passes) and #84 (a merge without a version bump never ships) — a stated rule that nothing executes.

### Version bumps

Per #84, the cache is keyed by version: **no bump, no ship.** Bump only where *behaviour*
changes — a comment that never ships is harmless, and bumping for prose is churn.

| Plugin | Bump | Rationale |
|---|---|---|
| `workspace-jj` | 0.1.1 → **0.1.2** | the skill, scripts, and command all change |
| `project-setup-jj` | 0.1.0 → **0.1.1** | the installed template's routing target changes |
| `permission-gateway` | none | comment-only |
| `agent-helpers-jj` | none | comment-only |

`.claude-plugin/marketplace.json` carries no `version` fields — verified 2026-07-15. Nothing to
bump there.

**Not affected:** runtime artifacts live at `/tmp/jj-workspaces/<repo>/artifacts`, which contains
no plugin name. No existing run state orphans.

**The version bump is load-bearing.** Per #84, the plugin cache is keyed by version string;
without the bump to 0.1.2, `claude plugin update` reports "already at the latest version" and
none of this reaches a live session.

## New: `tests/test-skill-paths.sh`

Bug C existed because nothing checks that a skill's relative paths resolve — the same silent-gap
class as #82 (a glob matching zero files passes) and #84 (a merge without a version bump never
ships). Prose is not executed, so it is not checked.

The lint walks every `skills/*/SKILL.md` under `plugins/`, extracts each relative script
reference (any `../`-prefixed path pointing into a `scripts/` directory), resolves it against the
skill file's own directory, and asserts the target exists.

Two rules keep the lint from becoming the thing it guards against:

1. **Zero references found across all skills ⇒ fail.** A lint that checks nothing must not pass
   silently — that is #82's exact failure. At least one skill in this repo references scripts; if
   the extractor matches nothing, the extractor is broken.
2. **A `../scripts/` reference (single `../`) from a `skills/<name>/SKILL.md` ⇒ fail** with an
   explicit message naming the correct depth. This is defect C's literal signature; catching it by
   name makes the next occurrence self-explaining.

**Anchoring is mandatory, not stylistic.** The string `../../scripts/` *contains* `../scripts/`.
A naive `grep '\.\./scripts/'` matches the correct fix and reports it as the bug — the lint fails
on the very thing it validates.

The anchor must be a **token boundary**, not merely a non-dot. `(^|[^.])\.\./scripts/` is *also
wrong*: in `../../scripts/` the inner `../scripts/` at offset 3 is preceded by `/`, which
satisfies `[^.]`, so it still false-positives. (This spec's first draft made exactly that error —
the trap is live, not theoretical.)

Verified pattern (tested against both forms, 2026-07-15):

```bash
grep -nE '(^|[[:space:]"'"'"'`(=$])\.\./scripts/'
```

| Input | Naive | `[^.]` anchor | Token anchor |
|---|---|---|---|
| `../../scripts/kaisen-artifacts` | ✗ match | ✗ match | ✓ no match |
| ``` `../../scripts/kaisen-artifacts` ``` | ✗ match | ✗ match | ✓ no match |
| `cat "$(../../scripts/kaisen-artifacts)/progress.md"` | ✗ match | ✗ match | ✓ no match |
| `../scripts/fan-flames-artifacts` | ✓ match | ✓ match | ✓ match |
| `"$(../scripts/fan-flames-artifacts)"` | ✓ match | ✓ match | ✓ match |

Equivalently, tokenise the path and count leading `..` segments. The same trap applies to reading
verification gate 5's output by eye.

## Verification

**Mechanical gates:**

1. `bash plugins/workspace-jj/tests/test-kaisen-scripts.sh` — passes
2. `bash plugins/workspace-jj/tests/test-model-selection-lint.sh` — passes
3. `bash plugins/workspace-jj/tests/test-skill-paths.sh` — passes (new)
4. `bash plugins/permission-gateway/tests/test-permission-gate.sh` — passes
5. `grep -rnE '(^|[[:space:]"'"'"'`(=$])\.\./scripts/' plugins/workspace-jj/` — **zero hits.** Use
   the anchored form; the naive `grep '\.\./scripts/'` matches `../../scripts/` too and will
   report the fix as the bug.
6. `grep -rn 'fan-flames' plugins/` — **zero hits.** This gate spans every plugin, and is
   deliberately broader than the inventory above: during spec self-review it was the gate, not the
   file list, that surfaced the cross-plugin references. Trust the gate over the list.
7. `grep -n 'workspace-jj:kaisen' plugins/project-setup-jj/templates/CLAUDE.md.template` — the
   installed template routes to the live name
8. Both bumped manifests read their new versions; `permission-gateway` and `agent-helpers-jj`
   are unchanged in version (comment-only edits, nothing to ship)
9. CI `validate` job runs and validates `skills/kaisen/SKILL.md`

**The gates that actually prove it** — after merge → bump → `claude plugin update` → restart:

1. **B is fixed:** invoke `Skill(workspace-jj:kaisen)` and confirm it returns the **skill body**,
   not a command. This is the probe that exposed the collision; nothing before it proves B.
2. **C is fixed:** from that loaded skill, actually **run** `../../scripts/kaisen-artifacts`
   resolved against the announced base directory, and confirm it prints an artifacts path. A
   static "the file exists on disk" check does not prove C — C is a *resolution* bug, and the
   resolution only happens at runtime, in the loaded context, which is the one place it has never
   been exercised.
3. **The template reaches projects:** run `/project-setup` against a project whose CLAUDE.md
   carries the old `hash:f2f52fd2` marker and confirm the section is **replaced** rather than
   skipped with "already up to date".

Gate 2 exists because C's whole history is a path that looked right on disk and was never
executed. Gate 3 exists because the hash silently defeats the version bump.

**Gate 10 — D is fixed:** CI's `validate` job goes green on *this* PR, which deletes two `.md`
files matching its filter. This PR is itself the test case for D; a green `validate` here proves
the fix, and a red one with `ENOENT` proves the filter was not applied.

Verify by **content**, never by version messages or success output. Three separate times today a
green signal was wrong: CI passed by never running, `plugin update` reported "already at the
latest version" while serving stale files, and #81 merged green with six broken paths.

## Related

- #77 — CI never validated skills (closed; premise was inverted)
- #81 — SKILL.md layout migration (fixed A, caused C)
- #82 — a validation glob matching zero files passes silently
- #83 — version bump to 0.1.1 (made #81 shippable)
- #84 — a merge without a version bump never ships
