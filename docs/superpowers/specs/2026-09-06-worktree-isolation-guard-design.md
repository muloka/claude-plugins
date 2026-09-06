# Worktree Isolation Guard × jj — Design

**Date:** 2026-09-06
**Status:** Approved design, revised after two-reviewer spec review; scoped for implementation

## Goal

Make a harness-isolated jj workspace (one made by `claude --worktree` or
`EnterWorktree` through the WorktreeCreate hook) a place where a thread can
still be finished unattended. Today every remote jj command is refused there,
so `/finish`'s push, fetch, verify and delete-last sequence cannot run and
each step is handed back to the human. The fix has three parts across three
plugins: `/finish` leaves the worktree before its remote phase, the session
briefing says at minute zero that the guard is active, and the docs route PR
work to the door that never had the problem.

## Background — measured facts

All measured on Claude Code 2.1.263 and jj 0.44.0, 2026-09-06, unless noted.

**The guard.**

- It runs in any session whose worktree Claude Code created or entered
  itself, including worktrees a WorktreeCreate hook produced. The docs say:
  "You can't turn this check off." `worktree.bgIsolation` covers background
  sessions only.
- For a plain command it scans every argument against an anchored `git`
  pattern. `jj git push` is therefore "a git command among its operands"
  behind a launcher it does not know (its launcher set is env / export /
  declare / make and friends). It has no notion of jj. Refused: `jj git push
  --bookmark X`, `jj -R <root> git push`, `cd <root> && jj git push`,
  `jj git fetch`, `jj git push --deleted`, and the read-only `jj git remote
  list`. Plain `jj log`, `jj workspace list`, `jj describe`, `jj status` pass.
- For a compound command (`&&`, pipes, subshells, `$(...)`, heredocs) it
  applies a bare `/git/i` to the whole text and otherwise refuses any shell
  shape it cannot model ("too complex to verify").
- No environment variable marks an isolated session (`env | grep -i
  worktree` inside one is empty). Detection has to come from the filesystem.
- **Hooks win in a colocated repo.** This repo has a `.git` directory, and
  both `claude --worktree` and `EnterWorktree` still went through the
  WorktreeCreate hook and produced `/tmp/jj-workspaces/<repo>/<name>`. The
  native `.claude/worktrees/` path (anthropics/claude-code#85118's scenario)
  arises only in a repo with no hooks configured, which project-setup never
  leaves behind.

**The escape.**

- **ExitWorktree with `keep` restores the pre-isolation state, for both
  doors.** Measured after `EnterWorktree` in-session and, separately, in two
  headless sessions launched with `claude --worktree`: the tool replied
  "Exited worktree. Your work is preserved at <root>. Session is now back in
  <main>", `jj workspace root` then returned the main checkout, `jj git
  remote list` ran, and a pipeline (`printf 'x' | wc -c`) ran. The workspace
  stays on disk and registered. This is the only sanctioned escape.
- The tool description says "Do NOT call this proactively — only when the
  user asks." When a prompt told the model to call it, it did, with no
  hesitation, in both headless runs. Prose that instructs the call must say
  the user's `/finish` choice *is* the ask.
- The tool description also says it "ONLY operates on worktrees created by
  EnterWorktree in this session" and not on "worktrees from a previous
  session". The `--worktree` launch case is measured to work regardless. A
  **resumed** session is not measured and is treated as the no-op case
  below.
- A wrapper script that hides the `git` token would pass the guard's check
  per its source, but the auto-mode classifier blocked even creating one.
  It is treated as guard evasion and is **not** part of this design.
- A workspace the harness did not create (`jj workspace add` by hand, plain
  `claude` inside it — the `jjtab` shell function) has no guard at all.

**jj facts the design leans on.**

- After ExitWorktree `keep`, the session is no longer "in" the worktree at
  exit time, so the WorktreeRemove hook never fires for it. Left alone, the
  directory and the workspace registration leak.
- jj snapshots a workspace only when a jj command runs *inside* it. Bytes
  written in the workspace after its last jj command are invisible from the
  main checkout. Measured: a file edited after the last snapshot read as the
  old content from main.
- `jj workspace forget` **abandons** the workspace's `@` when it is both
  empty and undescribed, and leaves it otherwise (empty+described,
  non-empty+undescribed, non-empty+described all survive). Measured matrix.
- **`trunk()` does not fail in a repo without a remote — it resolves to the
  root commit, exit 0.** `jj workspace add --revision <root>` then creates a
  workspace with no project files. `jj log -r 'trunk() ~ root()'` returns the
  empty string in that repo, which is the test a fallback needs.
- `jj workspace root` accepts `--ignore-working-copy` and returns the
  canonicalised path. On macOS `/tmp` is a symlink to `/private/tmp`, so a
  workspace the hook created at `/tmp/jj-workspaces/...` reports its root as
  `/private/tmp/jj-workspaces/...`. finish.md already carries this rule in
  prose; a shell `case` must carry both spellings.
- Upstream: #85118 (open) is the mirror image — colocated repo, no hooks,
  jj silently operates on the main checkout from `.claude/worktrees/`.
  Nobody has reported the too-strict side for hook-made workspaces. A
  comment there with the refused forms is a follow-up outside this spec.

**Prior art checked 2026-09-06.** No Claude Code release newer than 2.1.263
exists; the changelog has no jj-related worktree entry. Three community
jj-worktree projects (jasagiri/claude-jj-worktree, antstanley/jj-workspace-
skill, Benniphx/workspace-isolation-guide) all use WorktreeCreate hooks or
hand-made workspaces and none mentions pushing, fetching, the guard, or
ExitWorktree — nobody has documented this problem or a workaround. #85118 has
no maintainer response and no comment on the too-strict side. Its report that
an agent trusting jj's "no changes" from a native git worktree set
`discard_changes: true` and lost work is one more reason this design exits
with `keep`.

Related: `/ticket` (tokotoko) never enters a worktree itself; the FUT-757
session was launched with `claude --worktree`. `jjtab` already fixes the
launch door; the `/finish` change covers a `--worktree` launch anyway, or an
`EnterWorktree` mid-session.

## Decisions

| Question | Decision |
|---|---|
| How `/finish` escapes the guard | **Auto-exit with keep.** Choosing an option that needs remote commands implies it; the prose states that the choice is the user's ask. No extra prompt. |
| What happens to the ephemeral directory afterwards | **Forget and remove it**, through the WorktreeRemove hook script, only for a workspace the session itself left in this run. |
| Should the WorktreeCreate hook base on `trunk()` like `jjtab` | **Yes**, guarded: `trunk() ~ root()`, falling back to `@-` when that is empty. kaisen calls `jj workspace add` itself and does not depend on the hook's pin. |
| How `/finish` and the briefing detect isolation | **Path provenance**: current workspace root under `/tmp/jj-workspaces/` **or** `/private/tmp/jj-workspaces/`. No env var exists. The one false positive — kaisen workspaces use the same prefix and have no guard — is accepted: kaisen workers never run SessionStart or `/finish`. The refusal text is named in prose as the fallback tell. |
| `keep`, not `remove`, on exit | The change must be pushed and verified before anything is retired, and retirement goes through our own cleanup so forget-then-remove stays in one script. |

## Deliverables

### 1. `/finish` — leave the worktree before the remote phase (commit-commands-jj)

**Trigger.** The current workspace root (already in Context) is under either
spelling of the harness workspace prefix, **and** the chosen option needs a
remote command:

| Option | Remote command | Leaves the worktree |
|---|---|---|
| 1 push + PR | `jj git push`, `jj git fetch`, `jj git push --deleted` | yes |
| 2 merge into trunk locally (fast-forward) | `jj git fetch` (unconditional, step 1) | yes |
| 3 keep | none; never reaches Step 5 | no |
| 4 discard | `jj git push --deleted` if the bookmark was pushed (only if the user asks); and even unpushed, forgetting a workspace from inside it leaves the session with no working copy (measured: *No working copy*), unable to run the recovery it just handed back | yes |

(Revision 2: Option 4 always exits in a hook-made workspace; the first draft
exited only for a pushed bookmark.) Whether a bookmark was pushed is read in
Option 4 step 2 with a guard-safe, target-scoped probe, not from Context's
`@` line and not from `jj git remote list`:

```bash
jj bookmark list -r <target> --all-remotes
```

A `<name>@origin` row means pushed. A durable root (anything else) never
triggers this step; behaviour there is unchanged.

**New Step 3.5 — Leave the harness worktree.** Sits after option selection
(Step 3) and before every option's first command (Step 4), so each exiting
option runs it as its own first action:

1. **Snapshot inside the workspace.** Run `jj status`. Bytes the test suite
   or the user wrote since the last jj command become part of the change;
   without this they are unreachable from main and destroyed by cleanup.
2. **Record before moving**, all from inside the workspace:
   - the target's **change ID** (`jj log -r <target> --no-graph -T
     'change_id.short()'`) — after the exit `@` means the main checkout's
     working copy;
   - the workspace's **registry name**, asked of jj directly
     (`jj workspace list -T 'if(self.target().current_working_copy(), self.name() ++ "\n", "")'`
     — not by matching roots, which `self.root()` renders empty for moved or
     pre-0.38.0 workspaces) and its **root**.
   - (Revision 2) Option 4's op id is **not** captured here. Step 1's
     `jj status` snapshotted the workspace's bytes as a prior operation, so
     the op id Option 4 step 1 captures from main after the exit still
     covers them — measured: `jj op restore` from main restores the
     abandoned change intact. One capture, in Option 4, avoids two competing
     ids.
3. **Exit.** Call `ExitWorktree` with `action: "keep"`. The prose states:
   *"Selecting an option that pushes, fetches or deletes on the remote is
   the user asking to leave the worktree; call ExitWorktree now."* One line
   to the user: *"This session is worktree-isolated and the harness refuses
   every `jj git` command here. Leaving the worktree (kept on disk) and
   finishing from the main checkout."*
4. **If ExitWorktree reports no active worktree session** (a resumed
   session, or any other no-op/error), do not claim the exit happened. Fall
   back to the handoff: print the option's remaining remote commands, with
   the recorded change ID substituted, as one `! ` block for the user to
   run, and skip cleanup (the workspace is left for `/clean_stale`). This is
   the only path on which `/finish` hands back.
5. **Continue with the option's existing steps.** Revision references the
   prose already gives as change IDs use the recorded change ID; the one
   deliberate commit-ID inversion in Option 1's auto-delete recovery
   (finish.md:163-167) stands. Two effects of now running from main are
   stated in prose, not hidden: Option 1 step 6d's `jj new trunk()` and
   Option 2's end state re-point the **main checkout's** working copy, which
   is the intended end state for a finished thread. jj abandons main's old
   `@` only if it was empty and undescribed; parked non-empty work stays as
   its own change and is reported.

**Step 5 cleanup edits.** Step 5.1's "if the current workspace is `default`,
stop here" is amended: after Step 3.5 the current workspace *is* default by
construction, so Step 5 first checks whether Step 3.5 recorded a left
workspace and, if so, cleans up **that** one:

```bash
.claude/hooks/jj-workspace-remove.sh <recorded-root> <main-root>
```

The script gains positional arguments in deliverable 3 (stdin JSON remains
for the harness). Run from the main checkout root, which is where
ExitWorktree returns a session launched at the root; if `pwd` is not the
main root, prefix the script path with it. This runs whenever Step 3.5
exited, regardless of whether the user accepted Option 4's remote deletion.
If the script is absent (a repo that never ran project-setup), fall back to
`jj workspace forget <registry-name>` and report the directory path for the
user to remove by hand — `/finish` itself never runs `rm`. The script prints
nothing on success, so `/finish` reports what it ran and re-reads
`jj workspace list` to confirm the row is gone.

The provenance branches in Step 5.2 are unchanged for the no-exit case
(Option 4 unpushed stays inside; ephemeral roots are forgotten as today).

**Rule edits.**

- Both "never remove the directory" sites — Step 5.3 and the Important Rules
  bullet "Don't auto-remove worktree directories" — gain the same one
  exception: an ephemeral workspace this session left in Step 3.5, because
  the WorktreeRemove hook can no longer fire for it.
- `allowed-tools` gains `ExitWorktree` and
  `Bash(.claude/hooks/jj-workspace-remove.sh:*)`.
- The forget-abandons contingency from the first draft is dropped: measured,
  forget abandons an empty undescribed `@` and leaves anything else, and
  either outcome is fine after the change is pushed.

### 2. Session-start briefing — the guard notice (project-setup-jj)

`jj-session-start.sh` emits one additional block when the current workspace
root matches either spelling of the harness prefix:

```
== Worktree isolation ==
This workspace was created by the WorktreeCreate hook, so the harness guard
is active: every `jj git` command (push, fetch, remote) will be refused here,
and so will compound shell commands (pipes, &&, subshells). Before any remote
step, call ExitWorktree with action keep and continue from the main checkout;
bookmarks and changes are repo-global. Or hand the command to the user as
`! jj git ...`.
```

The text is version-independent: it does not promise what another plugin's
`/finish` does. The root comes from `jj workspace root --ignore-working-copy`,
placed **after** the `jj status` snapshot so the suite's ordering lint
(snapshot point precedes every `--ignore-working-copy` read) keeps passing.
The hook's comment block explains at length why the previous `jj workspace
root` call was retired (row matching against `self.root()`); a sentence is
added saying the new use is a prefix test on the live path, not a comparison
against a recorded one, so it does not reintroduce that bug.

**Both copies change**: `plugins/project-setup-jj/scripts/jj-session-start.sh`
and this repo's own `.claude/hooks/jj-session-start.sh`, which
`.claude/settings.json` actually runs. The repo copy is **already behind** the
plugin source (it lacks the `current_working_copy()` marker rewrite); the
implementation re-syncs it from the plugin rather than patching both by hand.

**Limit, stated in the hook comment and README:** SessionStart does not
re-run on a mid-session `EnterWorktree`; that case is covered by deliverable
1 alone.

### 3. Worktree hooks (project-setup-jj)

**Create hook — base on `trunk()`, guarded.**

```bash
base=$(jj -R "$cwd" log -r 'trunk() ~ root()' --no-graph -T 'commit_id' 2>/dev/null || true)
[ -n "$base" ] || base=$(jj -R "$cwd" log -r '@- ~ root()' --no-graph -T 'commit_id' 2>/dev/null || true)
[ -n "$base" ] || base=$(jj -R "$cwd" log -r '@ ~ root()' --no-graph -T 'commit_id' 2>/dev/null || true)
```

Then `--revision "$base"` if non-empty, else no `--revision`, as today. The
comment is rewritten around the two hazards: a thread based on `@-`
inherits whatever is parked there, including an undescribed empty change
that later blocks `jj git push`; and `trunk()` alone silently means the root
commit in a repo with no remote. The fallback is `@- ~ root()`, not plain
`@-`, for the same reason: in a fresh repo (only `@` with files, parent =
root) `@-` IS the root commit, and without the subtraction this tier would
silently reproduce the empty-workspace bug tier 1 exists to avoid.

**Amendment found during final-review fix-up (measured, jj 0.44):** falling
all the way through to jj's own no-`--revision` default does NOT recover
that fresh-repo case. `jj workspace add` with no revision makes the new
workspace a SIBLING of the source `@` — same parents, not a copy of `@`
itself — so when `@`'s parent is root (the fresh-repo case), the sibling is
just as empty as the bug this guard exists to fix. A third guarded tier,
`@ ~ root()`, is required: passing `--revision` = `@` makes the new
workspace a CHILD of `@`, which checks out `@`'s content. Only a truly
virgin repo (`@` itself is root, nothing committed at all) has nothing left
for any tier to resolve, and only that case still falls through to jj's
default. The kaisen fan-out sentence goes, since kaisen does not call this
hook.

Trade-off, stated in the comment: with a real origin, `trunk()` is
`main@origin`. A local `main` that is ahead of origin (Option 2 merged
locally, push not yet asked for) is a transient state, and a spike based on
`main@origin` during it omits the local merge. A deliberate stacked
follow-up on current context is `jjtab <name> '@-'` territory, not this
hook's.

**Remove hook — positional arguments and correct names.** Accepts
`<worktree_path> <cwd>` as arguments, falling back to the stdin JSON the
harness sends. Derives the workspace name from the path **relative to
`/tmp/jj-workspaces/<repo>/`**, not `basename`, because EnterWorktree allows
`/`-separated names: today `feat/auth` is registered as
`workspace-feat/auth` and the remove hook tries to forget `workspace-auth`,
swallows the failure, and removes the directory anyway, leaving a dead
registration. Both `/tmp` and `/private/tmp` prefixes are stripped; a
trailing slash is stripped. (Revision 2) Because `/finish` can now supply the
path and the script ends in `rm -rf`, it **refuses any path outside
`/tmp/jj-workspaces/<repo>/`** (exit 2, nothing touched).

Both hooks change in both copies (`plugins/project-setup-jj/scripts/` and
this repo's `.claude/hooks/`); the create/remove pairs are byte-identical
today.

### 4. workspace-jj README — reroute the doors

- Lines 11-13, which describe the WorktreeCreate hook as "`--revision @-`
  … pinned to the parent revision", are rewritten to match deliverable 3.
- The Usage block stops leading with `claude --worktree feature-auth`.
- The door table gets a one-line statement of the guard above it and is
  rerouted. `jjtab` is a terminal door only (it ends in `cd && claude`);
  Claude cannot route itself there mid-session, which is why deliverable 1
  exists.

  | Situation | Use |
  |---|---|
  | New tab, anything that ends in a PR | `jjtab <name> [revset]` (no guard) |
  | New tab, read-only spike | `claude --worktree <name>` (guarded) |
  | Already in a session, read-only spike | `EnterWorktree` (guarded; cannot enter a `jjtab` workspace) |
  | In a guarded workspace and need to push | `ExitWorktree` with keep, then push from main; `/finish` does this itself from commit-commands-jj 0.20 |
  | Parallel agent execution of a plan | `/kaisen` (unguarded; it manages workspaces itself) |

- The `jjtab` function is replaced with the shell version in use: base on
  `trunk()`, directory `<repo>-ws/NAME`, refuses to run from inside a `-ws`
  workspace, and (Revision 2) creates the `<repo>-ws/` parent first —
  `jj workspace add` fails with *Cannot access ... No such file or directory*
  when it is missing, which the `~/.zshrc` copy also needs fixed. Its comment
  names the guard as the reason for plain `claude`.
- The repo-root `README.md` setup block, which still shows
  `claude --worktree feature-auth` as step 3, is rerouted the same way.
- The divergent-change rule paragraph and the cleanup section stay.

## Error handling and edge cases

- **ExitWorktree no-ops or errors** (resumed session, or anything
  unmeasured): deliverable 1 step 4 — say so, hand back one `! ` block,
  skip cleanup. Never print the "leaving the worktree" line before the tool
  has confirmed.
- **The push fails after the exit.** The session stays in the main checkout;
  the workspace is intact on disk and registered; the change is reachable by
  its recorded change ID from anywhere. `/finish` reports the failure and
  the change ID and stops. Re-entering by path is not possible (EnterWorktree
  requires `git worktree list`); the user can `cd` into the directory and
  run plain `claude` there, which is unguarded.
- **Main's parked `@`.** Stated in deliverable 1 step 5. Nothing is lost;
  files on disk in main change to the merged trunk, which is the intended
  end state.
- **kaisen workspaces** share the prefix and have no guard. Workers never run
  SessionStart or `/finish`; a human who launches plain `claude` inside one
  would see a briefing notice that is wrong for them. Accepted; the notice
  names the hook as the reason so the reader can tell.
- **Colocated repo with no hooks** (`.claude/worktrees/`, #85118): out of
  scope. Running `/project-setup` installs the hooks, and hooks win.
- **A subagent invoking `/finish`** from a pinned-cwd agent: out of scope;
  ExitWorktree there affects only that agent.
- **A repo whose `/tmp` is the repo's own parent**: the prefix test is on the
  harness directory `jj-workspaces/<repo>/`, not on `/tmp` alone.

## Testing

- **test-command-prose-claims.sh** (commit-commands-jj), three assertions on
  finish.md, all scoped to fenced code blocks and the named section so
  frontmatter and the CRITICAL paragraph cannot satisfy them: (a) inside
  Step 3.5, `ExitWorktree` precedes the first executable `jj git`; (b) the
  sentence declaring the option choice as the user's ask is present
  verbatim; (c) both never-remove sites carry the same exception text.
- **test-jj-session-start.sh** (project-setup-jj), three cases: a workspace
  rooted under a unique subdirectory of the real `/tmp/jj-workspaces/`
  (removed by the suite's trap) emits the `Worktree isolation` block; the
  default workspace does not; a sibling-directory workspace does not. On
  macOS the first case exercises the `/private/tmp` spelling for free. The
  op-count and ordering lints must keep passing with the added read.
- **New suite `plugins/project-setup-jj/tests/test-jj-workspace-hooks.sh`**
  (auto-discovered by the CI glob), scratch repo under a sandbox
  `JJ_CONFIG`, two arms for the create hook — with an origin `main`
  (`trunk()` real): the workspace's parent is trunk **and the workspace
  contains the repo's files**, in a repo where the default workspace's `@-`
  is deliberately not trunk; without a remote: the hook falls back to `@-`
  and the workspace contains the files. Both arms are required: the
  with-origin arm alone is the configuration under which the root-commit
  bug is invisible. Remove hook: positional and JSON forms both forget and
  remove; a `feat/auth`-style name is forgotten under its real registry
  name. The existing install suite is stub-based and has no jj; it is not
  the place for these.
- **Manual dry run before any finish.md prose**, in this repo:
  `claude --worktree <probe>`, run the Step 3.5 sequence by hand — `jj
  status`, record, ExitWorktree keep — then push a throwaway bookmark,
  verify, and run the positional remove hook from main. Confirms the
  compound-command clearance and the cleanup command shape in one pass.
- **In-session check after shipping**: `claude --worktree` in this repo,
  confirm the briefing shows the notice, run `/finish` option 1 end to end
  with no `! jj git` handoff.

## Shipping

Three plugins change; each gets a version bump (CI enforces
version-bump-on-diff) and its own PR:

| Order | Plugin | From | Change |
|---|---|---|---|
| 1 | project-setup-jj | 0.19.2 | briefing notice, create-hook base, remove-hook arguments and names, new hook suite, session-start suite |
| 2 | commit-commands-jj | 0.19.0 | Step 3.5, Step 5 edits, rule edits, prose-claims assertions |
| 3 | workspace-jj | 0.4.0 | README reroute, hook description, `jjtab` |

Order matters once: `/finish`'s cleanup calls the remove hook with
positional arguments, which exist only after PR 1 has shipped **and** the
project has re-run `/project-setup` to refresh its installed hook copies
(three layers go stale independently: source → cache → installed copy).
Until then the fallback path (forget, report the directory) is what runs.
Cross-plugin prose is version-independent everywhere except the README's
explicit "from commit-commands-jj 0.20" note.

## Out of scope

- Any wrapper or renamed binary that hides the `git` token from the guard.
- Changing kaisen: it dispatches without harness isolation and is unaffected.
- The upstream issue comment (a follow-up, not a code change).
- A CLAUDE.md template line about the guard: the briefing fires only when
  relevant; a template line would cost tokens in every session.
- Repos without hooks configured (`.claude/worktrees/`, #85118).
