# Invariant Lints Implementation Plan (#82, #86)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Do NOT use workspace-jj:kaisen.** Three small tasks; Task 3 depends on Tasks 1–2 existing, so
> the overlap graph is a chain. Sequential inline execution is correct.

**Goal:** Enforce two rules the repo states but nothing checks — every validation-workflow glob
matches ≥1 file (#82), and the project-setup template's `hash:` marker equals its body hash (#86).

**Architecture:** Two `#!/usr/bin/env bash` lint suites in the house `ok()`/`bad()` style, each
written to fail first. #86's lives under `plugins/project-setup-jj/tests/` (already discovered).
#82's lives under `.github/tests/` and requires a one-word extension to #89's runner glob so it is
discovered too.

**Tech Stack:** bash (not zsh — the lints use `shopt`, absent in this repo's interactive zsh),
jj, GitHub Actions, `md5`/`md5sum`.

## Global Constraints

- **jj, never git.** Raw `git` is blocked by a hook. Exceptions: `jj git` subcommands, `gh`.
- **Test lints with `bash <script>`, never by sourcing.** The interactive shell is zsh; `shopt`
  does not exist there. The `#!/usr/bin/env bash` shebang is load-bearing.
- **A lint that finds nothing to check must FAIL, not pass.** Zero globs extracted, or a missing
  hash marker, means the lint is broken, not the repo clean. This is the #82 disease and both lints
  must be immune to it.
- **Extract, never hardcode.** #82's lint parses the workflow's `paths:`; it does not carry its own
  copy of the glob list.
- **No hardcoded suite/glob count anywhere.** Count rules are `> 0` only.
- **Every lint is written to fail first** (like `test-skill-paths.sh`, #85). A lint green on its
  first run has proved nothing.
- Spec: `docs/specs/2026-07-16-invariant-lints-design.md`

---

### Task 1: Template hash lint (#86)

**Files:**
- Create: `plugins/project-setup-jj/tests/test-template-hash.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: a suite the runner already discovers (`plugins/*/tests/`). No later task depends on it.

- [ ] **Step 1: Write the lint**

Create `plugins/project-setup-jj/tests/test-template-hash.sh`:

```bash
#!/usr/bin/env bash
# Verifies the project-setup CLAUDE.md template's hash: marker equals the hash
# of its own body.
#
# Why this exists (#86): /project-setup skips the CLAUDE.md update when the
# installed marker's hash equals the template's. So editing the template body
# without recomputing the hash means the change reaches nobody, while
# /project-setup reports "already up to date". This repo's own CLAUDE.md was
# stale for four months for exactly this reason (#87). The recipe was
# documented in commands/project-setup.md (#85); this makes it executable.
#
# Usage: test-template-hash.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$ROOT/plugins/project-setup-jj/templates/CLAUDE.md.template"
PASS=0
FAIL=0

ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Portable md5-of-stdin -> first 8 hex (md5 on macOS, md5sum on Linux).
_md5_8() { if command -v md5 >/dev/null 2>&1; then md5; else md5sum; fi | cut -c1-8; }

# --- fail loudly if the structure the check depends on is missing ---
if ! grep -q 'jj-project-setup:start' "$T"; then
  bad "no start marker in $T — cannot verify the hash"
elif ! grep -q 'jj-project-setup:end' "$T"; then
  bad "no end marker in $T — body extraction would be meaningless"
else
  declared=$(sed -n '1s/.*hash:\([0-9a-f][0-9a-f]*\).*/\1/p' "$T")
  if [ -z "$declared" ]; then
    bad "start marker has no parseable hash: — got '$(sed -n '1p' "$T")'"
  else
    recomputed=$(sed -n '/jj-project-setup:start/,/jj-project-setup:end/p' "$T" | sed '1d;$d' | _md5_8)
    if [ "$declared" = "$recomputed" ]; then
      ok "template hash $declared matches its body"
    else
      bad "template hash is stale: marker says $declared, body hashes to $recomputed — rerun the recipe in commands/project-setup.md or the update reaches nobody"
    fi
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
```

- [ ] **Step 2: Make it executable and prove it FAILS on a stale hash**

```bash
cd /Users/muloka/projects/sonder-hale/tools/claude-plugins
chmod +x plugins/project-setup-jj/tests/test-template-hash.sh
cp plugins/project-setup-jj/templates/CLAUDE.md.template /tmp/tmpl.bak
# Corrupt only the marker's hash, leave the body untouched:
sed -i '' '1s/hash:[0-9a-f]*/hash:deadbeef/' plugins/project-setup-jj/templates/CLAUDE.md.template
bash plugins/project-setup-jj/tests/test-template-hash.sh; echo "exit: $?"
```

Expected: **FAIL**, `exit: 1`, message naming `marker says deadbeef, body hashes to fe023f83`. If
this PASSES, the lint is not actually comparing — stop and fix it.

- [ ] **Step 3: Restore and prove it PASSES**

```bash
cp /tmp/tmpl.bak plugins/project-setup-jj/templates/CLAUDE.md.template
bash plugins/project-setup-jj/tests/test-template-hash.sh; echo "exit: $?"
```

Expected: **PASS**, `exit: 0`, `template hash fe023f83 matches its body`, `1 passed, 0 failed`.

- [ ] **Step 4: Prove the missing-marker guard fires (fail-loudly-on-nothing)**

```bash
printf 'no markers here\n' > /tmp/nomarker.template
ROOT_OVERRIDE=1 bash -c '
  T=/tmp/nomarker.template
  grep -q "jj-project-setup:start" "$T" && echo "UNEXPECTED: found marker" || echo "correctly detects missing start marker"
'
```

Expected: `correctly detects missing start marker`. This confirms the branch that makes a
marker-less template a failure rather than a silent pass. (The real lint hard-codes the template
path; this checks the guard logic directly.)

- [ ] **Step 5: Commit**

```bash
jj commit -m "test(project-setup): lint the CLAUDE.md template hash (#86)

The template's hash: marker gates /project-setup's update: equal hashes
mean skip. Editing the body without rehashing means the change reaches
nobody while /project-setup reports 'already up to date' — this repo's
CLAUDE.md was stale four months for exactly that (#87).

The recipe was documented in #85; this makes it executable. Fails
loudly on a missing/unparseable marker — a hash-checker that finds no
hash is the bug, not the repo clean.

Written to fail first: verified red on a corrupted marker, green on
restore."
```

---

### Task 2: Workflow-glob lint (#82)

**Files:**
- Create: `.github/tests/test-workflow-globs.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: a suite under `.github/tests/`. **Task 3 makes the runner discover it** — until Task 3,
  it runs only when invoked directly.

- [ ] **Step 1: Write the lint**

Create `.github/tests/test-workflow-globs.sh`:

```bash
#!/usr/bin/env bash
# Verifies every glob a validation workflow relies on matches at least one file.
#
# Why this exists (#82): validate-frontmatter.yml gates on `paths:` globs. A
# glob that matches nothing means the workflow never triggers, which on GitHub
# is indistinguishable from passing — green tick, no check. `**/skills/*/SKILL.md`
# matched ZERO files for months (#77) and nobody noticed.
#
# This CANNOT live inside validate-frontmatter.yml: that workflow only triggers
# on the very globs it would check, so a dead glob means no trigger means no
# check — the same circularity. It runs unconditionally via the test runner
# (.github/workflows/test.yml, no paths: filter).
#
# The globs are EXTRACTED from the workflow, never hardcoded: a hardcoded copy
# would go stale when a glob is added — #82 inside the fix for #82.
#
# Usage: test-workflow-globs.sh
set -euo pipefail
shopt -s globstar nullglob   # bash-only; the shebang matters (zsh has no shopt)

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$ROOT/.github/workflows/validate-frontmatter.yml"
PASS=0
FAIL=0

ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Extract the quoted entries under `paths:` in the workflow.
globs=$(awk '
  /^[[:space:]]*paths:/ {inpaths=1; next}
  inpaths && /^[[:space:]]*-[[:space:]]/ {
    line=$0
    sub(/^[[:space:]]*-[[:space:]]*/, "", line)
    gsub(/^['\''"]|['\''"]$/, "", line)
    print line
    next
  }
  inpaths && /^[[:space:]]*[^[:space:]-]/ {inpaths=0}
' "$WF")

# fail loudly if we extracted nothing — a glob-checker that checks no globs is
# the bug (#82 applied to itself).
n=$(printf '%s\n' "$globs" | grep -c .)
if [ "$n" -eq 0 ]; then
  bad "no paths: globs found in $WF — the parser or the workflow changed"
else
  ok "extracted $n glob(s) from validate-frontmatter.yml"
  cd "$ROOT"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    matches=( $g )
    if [ "${#matches[@]}" -gt 0 ]; then
      ok "$g matches ${#matches[@]} file(s)"
    else
      bad "$g matches ZERO files — the workflow gates on it but it is dead (see #77)"
    fi
  done <<< "$globs"
fi

echo
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
```

- [ ] **Step 2: Make it executable and prove it PASSES on the real repo**

```bash
cd /Users/muloka/projects/sonder-hale/tools/claude-plugins
chmod +x .github/tests/test-workflow-globs.sh
bash .github/tests/test-workflow-globs.sh; echo "exit: $?"
```

Expected: **PASS**, `exit: 0`. Lines: `extracted 3 glob(s)`, then
`**/agents/*.md matches 1 file(s)`, `**/skills/*/SKILL.md matches 3 file(s)`,
`**/commands/*.md matches 24 file(s)`, then `4 passed, 0 failed`.

- [ ] **Step 3: Prove it FAILS on a dead glob (the #77 scenario)**

```bash
cp .github/workflows/validate-frontmatter.yml /tmp/wf.bak
# Add a glob that matches nothing — exactly the shape of the #77 bug:
sed -i '' "s|      - '\*\*/commands/\*.md'|      - '**/commands/*.md'\n      - '**/nonexistent/*.md'|" \
  .github/workflows/validate-frontmatter.yml
bash .github/tests/test-workflow-globs.sh; echo "exit: $?"
```

Expected: **FAIL**, `exit: 1`, a line `**/nonexistent/*.md matches ZERO files`. The lint sees the
dead glob the same way #77 should have been seen.

- [ ] **Step 4: Restore and confirm green again**

```bash
cp /tmp/wf.bak .github/workflows/validate-frontmatter.yml
bash .github/tests/test-workflow-globs.sh; echo "exit: $?"
```

Expected: **PASS**, `exit: 0`, `4 passed, 0 failed`.

- [ ] **Step 5: Prove the zero-globs guard fires**

```bash
printf 'name: x\non:\n  push:\n' > /tmp/noglobs.yml
awk '
  /^[[:space:]]*paths:/ {inpaths=1; next}
  inpaths && /^[[:space:]]*-[[:space:]]/ { print "GLOB"; next }
  inpaths && /^[[:space:]]*[^[:space:]-]/ {inpaths=0}
' /tmp/noglobs.yml | grep -c . 
```

Expected: `0`. Confirms that a workflow with no `paths:` yields zero globs, which the lint treats
as a failure (`no paths: globs found`), not a silent pass.

- [ ] **Step 6: Commit**

```bash
jj commit -m "test(ci): lint that every validate-frontmatter glob matches a file (#82)

A paths: glob that matches nothing means the workflow never triggers,
which on GitHub is indistinguishable from passing. **/skills/*/SKILL.md
matched zero for months (#77) and nobody noticed.

Lives in .github/tests/, not inside validate-frontmatter.yml: that
workflow only triggers on the globs it would check, so a dead glob means
no trigger means no check — the same circularity. It runs via the
always-on test runner.

Globs are extracted from the workflow, never hardcoded — a hardcoded
copy is #82 inside the fix. Fails loudly if zero globs are extracted.

Written to fail first: verified red on an injected dead glob, green on
the real three (1/3/24 files)."
```

---

### Task 3: Extend the runner to discover `.github/tests/`

Until this, Task 2's lint exists but CI never runs it — which would be #82 in miniature (a check
that does not run). One word closes it.

**Files:**
- Modify: `.github/workflows/test.yml` (the discovery line)

**Interfaces:**
- Consumes: the two lint files from Tasks 1–2 must exist.
- Produces: a CI run that discovers 9 suites.

- [ ] **Step 1: Extend the discovery glob**

In `.github/workflows/test.yml`, replace:

```bash
          suites=$(find plugins -path '*/tests/test-*.sh' | sort)
```

with:

```bash
          # plugins/*/tests AND .github/tests: the latter holds repo-level
          # lints (e.g. workflow-glob checks) that belong to no single plugin.
          suites=$(find plugins .github -path '*/tests/test-*.sh' | sort)
```

- [ ] **Step 2: Run the full discovery locally under bash -e**

```bash
cd /Users/muloka/projects/sonder-hale/tools/claude-plugins
bash -e -c '
suites=$(find plugins .github -path "*/tests/test-*.sh" | sort)
count=$(printf "%s" "$suites" | grep -c . || true)
[ "$count" -gt 0 ] || { echo "::error::no suites"; exit 1; }
echo "found $count suite(s)"
failed=0
while IFS= read -r t; do
  [ -n "$t" ] || continue
  if bash "$t" >/dev/null 2>&1; then echo "  PASS $t"; else echo "  FAIL $t"; failed=$((failed + 1)); fi
done <<< "$suites"
echo "$((count - failed))/$count suites passed"
[ "$failed" -eq 0 ]
'
echo "exit: $?"
```

Expected: `found 9 suite(s)`, nine `PASS` lines including
`.github/tests/test-workflow-globs.sh` and
`plugins/project-setup-jj/tests/test-template-hash.sh`, `9/9 suites passed`, `exit: 0`.

- [ ] **Step 3: Commit**

```bash
jj commit -m "ci: discover repo-level lints under .github/tests too

The runner globbed only plugins/*/tests. #82's workflow-glob lint is a
repo-level check (it belongs to no plugin), so without this it would sit
in .github/tests and never run — a check that does not run, which is the
bug #82 is about.

find plugins .github -path '*/tests/test-*.sh' keeps glob-discovery (no
hardcoded list) and finds both roots. Now 9 suites."
```

---

## PR verification

Local runs prove the shell; only CI proves the workflow. Same discipline as #89.

- [ ] **Step 1: Push and open the PR**

```bash
jj git push --change @-
gh pr create --base main --head <bookmark> \
  --title "ci: invariant lints for #82 and #86" \
  --body "Closes #82, #86. Two static lints run by #89's runner (extended to .github/tests). See docs/specs/2026-07-16-invariant-lints-design.md."
```

- [ ] **Step 2: Read the log — confirm 9 suites, both new lints named**

```bash
gh run view <run-id> --log | grep -E "found [0-9]+ suite|PASS .*(workflow-globs|template-hash)|suites passed"
```

Expected: `found 9 suite(s)`, both `.github/tests/test-workflow-globs.sh` and
`plugins/project-setup-jj/tests/test-template-hash.sh` appear as `PASS`, `9/9 suites passed`.
**Read the log, not the tick** — a run that found 8 and passed 8 is green and wrong.

- [ ] **Step 3: Merge**

```bash
gh pr merge <PR> --squash
```

Then clean up: `jj git fetch`, `jj bookmark delete <name>`, `jj git push --deleted`,
`jj new main`, and abandon the merged local changes with a **dry-run of the revset first**
(`jj log -r '<range>'` before `jj abandon '<range>'`).

## What this does not do

- **Does not touch #84** — needs the PR diff, a different mechanism.
- **Does not change how `validate-frontmatter.yml` triggers.** #82's lint *detects* a dead glob; if
  one is found, correcting it (glob vs. layout) is a human decision — the #77 pattern.
- **Does not auto-recompute the template hash.** The lint catches drift; it does not hide the edit
  the maintainer should notice.
