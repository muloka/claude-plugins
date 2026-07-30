# permission-gateway

Tiered permission gateway for Claude Code — auto-approves safe commands, blocks dangerous ones, confirms risky operations, and LLM-evaluates everything else.

## Why

When running 3-5 subagents in parallel (e.g., kaisen), each making 20+ tool calls, you either pre-approve everything (dangerous) or get 60+ confirmation prompts (kills parallelism). Permission gateway is the middle ground: ~85% auto-approved, ~10% auto-denied, ~5% human-confirmed.

## How It Works

```
Tool call → Gate-the-Gate → Deny (immutable) → .local.md → Confirm → Approve → Tier 2 LLM
```

Seven evaluation stages, one exit per command. Each decision is logged for rule self-tuning.

| Tier | Action | Examples |
|------|--------|---------|
| **Gate-the-Gate** | Confirms config writes | Any write — Write, Edit, or Bash — to `*permission-gate*`, `.claude/settings*`, `.claude/hooks/`, `.claude/scripts/`, or `.claude-plugin/` paths |
| **Deny** | Blocked, never runs | `rm -rf /`, `sudo`, `eval`, `dd`, `kill -9` |
| **Confirm** | Human sees prompt | `npm publish`, `ssh`, `mv`, `docker run`, `xargs` |
| **Approve** | Silent, no prompt | `ls`, `npm test`, `jj log`, `cargo build`, `grep` |
| **Tier 2** | LLM evaluates, then human confirms | Unknown commands |

## Security

**One-way ratchet:** Hardcoded deny runs before `.local.md` rules. No override can loosen a deny — the deny tier is an immutable floor. This prevents prompt injection attacks where malicious content instructs Claude to write `.local.md` rules promoting dangerous commands.

**Gate the gate:** Writes to the gateway's own scripts/config (`*permission-gate*`), hook registration (`.claude/settings*`), the hook scripts themselves (`.claude/hooks/`, and `.claude/scripts/` for projects that predate the move), or the plugin manifest (`.claude-plugin/`) trigger a human confirmation prompt. The injection attempt is caught before the file is modified.

This is enforced on **two** paths, because one is not enough. `gate-config-writes.sh` covers the `Write` and `Edit` tools. `permission-gate.sh` covers `Bash`, which reaches the same files four ways — a redirect target (`>` and `>>` alike), a write verb such as `tee`, `cp`, `dd`, `install` or `truncate`, a `cd` into a protected directory followed by a write to a bare filename, or a write whose target cannot be read statically at all. Every one of these returned *no decision at all* rather than a prompt before #123.

Matching runs on a quote-stripped, separator-normalized copy of the command, and captures whole command segments rather than single tokens. A literal substring test reads only the path as written, so `.claude//settings.json`, `.claude/./settings.json`, `cd '.claude'` and `> $(echo .claude/settings.json)` all reach the same files while matching nothing. Every equivalent spelling is otherwise a separate hole.

Only writes are gated — reading or grepping a protected path stays silent, or the prompt becomes noise on ordinary inspection and gets tuned out. Where precision and safety conflict the gate over-asks: any argument of a write verb counts as a candidate destination rather than parsing flags for the real one, and any `$` or backtick in a target makes it unreadable and therefore worth a prompt. So `echo x > $OUT` asks, while `echo $VERSION > version.txt` — dynamic on the *source* side, literal target — stays silent.

### Why the last rule is about the safelist, not the paths

The Tier-1 safelist approves on the **leading verb alone**, and `echo`, `cat`, `cd` and `cp` are all on it. That means a protected-path check that fails to recognise a spelling does not degrade to "no opinion" — it degrades to an explicit approve, several dozen lines later. Every bypass found during review reached the filesystem through that amplifier rather than through the gap itself. Treating an unreadable target as a prompt is what stops an unrecognised shell construct from becoming an approval.

### The backstop: enumerate reads, not writes

The routes above enumerate ways to **write**, and that list cannot be completed. Four rounds of adding shapes did not converge — relative and `cd` forms, then quoted directory names and `cp -t DEST src`, then command substitution, then ANSI-C quoting — and two classes were immune to the whole approach on principle. A glob means the path is only known after expansion, so `.claude/set*.json` never contains the literal `.claude/settings`. And *any* binary can be a write verb: `sponge` names its target in plain text, matches no route, and then `cat` satisfies the safelist.

So the burden is inverted. The set of write commands is unbounded, but a **read allowlist** is finite and, crucially, fails in the safe direction: a verb nobody thought of is not on it, so it blocks. A command that names a protected path and is not purely a read loses Tier-1 auto-approval and falls through to Tier 2 for a prompt. A redirect counts as a write whatever the verb, since `echo` is a read command and `echo x > .claude/settings.json` is not a read.

**The allowlist is therefore the security boundary, and each member needs auditing in its own right.** "Bounded and written down" is a claim about the set; it says nothing about whether the members are actually read-only. The first version of the list admitted a long tail of verbs that were not: `env` runs another program, so `env cp x .claude/settings.json` classified as a read and defeated the mechanism generically; `sed`'s `w` and `e` commands write and execute without `-i` or a redirect; `awk` has `system()`; `sort -o`, `uniq OUT`, `tree -o`, `xxd -r in out` and `file -C` all write a named file; `find -ok` is not the literal `-exec` an older rule matched; `fd -x` and `rg --pre` run programs.

The admission rule is **any documented write or exec, not one that looks dangerous**. `file -C` compiles a magic file to `<name>.mgc` and cannot overwrite a hook by name, which is precisely why it is easy to wave through — it was caught by auditing the trimmed list, after review had already been round it. Every exclusion carries its reason beside the list in the script, so none gets helpfully added back.

What the shape does buy is that the failure direction is right. Wrappers nobody enumerated — `nice`, `timeout`, `nohup`, `stdbuf`, `command`, `exec`, `busybox` — all prompt, because they were never on the allowlist. Only a wrongly-admitted member is dangerous.

Nothing has to be named for this to hold, which is the point — the next unenumerated construct will not be named either. It closes shapes never written down anywhere: `ln -sf /evil .claude/settings.json` and `touch .claude/hooks/evil.sh` were both **silently auto-approved** before it existed, since `ln` and `touch` sit on the safelist.

Reads stay silent: `cat .claude/settings.json`, `ls -la .claude/` and `grep -r x .claude/hooks/` are all untouched. That is the property the read-set is enumerated to preserve.

**Remaining limit.** The route matching is still shape-based and still cannot be proved exhaustive; what changed is that a miss now degrades to a prompt rather than to an approval. The backstop governs the Tier-1 safelist specifically — the `.local.md` approve path runs earlier and is not covered, though those files are themselves protected, so reaching it needs a hand-written rule rather than a planted one. #123 tracks full argument resolution.

The two copies of the protected-path set are held identical by `tests/test-protected-paths-parity.sh`; drift between them would silently reopen the gap on whichever tool the stale copy handles, with every other suite still green.

**Full-string scanning:** Dangerous patterns (`rm -rf`, `> ~/path`) are scanned in the full command string, not just the leading command. This prevents bypass via wrappers like `find -exec`, `xargs`, or redirect clobbers to paths outside the project directory.

## Configuration

Zero-config out of the box. Customize via `.local.md` files:

```yaml
# .claude/permission-gateway.local.md
---
rules:
  approve:
    - "terraform plan"
    - "kubectl get *"
  deny:
    - "terraform apply"
  ask:
    - "docker push"
---
```

The markdown body (after the closing `---`) is for human context — notes on why rules exist. Only the YAML frontmatter is parsed by the gateway.

| Level | Location | Precedence |
|-------|----------|-----------|
| Plugin defaults | Hardcoded in `permission-gate.sh` | Lowest |
| User global | `~/.claude/permission-gateway.local.md` | Middle |
| Project | `<project>/.claude/permission-gateway.local.md` | Highest |

## Decision Logging

All decisions logged to `.claude/permission-gateway.log`:

```
2026-03-19T04:15:23Z APPROVE npm test
2026-03-19T04:15:24Z DENY    sudo rm /etc/hosts
2026-03-19T04:15:25Z CONFIRM docker run ubuntu
```

Review the log to promote frequently-confirmed commands to `.local.md` approve rules. The list self-tunes over time.

## Self-Tuning

After accumulating log data, use `/tune` to promote frequently-confirmed commands:

```
/tune                    # scan project log, suggest promotions (threshold: 10)
/tune --threshold 5      # lower threshold
/tune --global           # scan/update user-global rules instead
```

The command scans the log, normalizes commands into patterns (`pip install requests` → `pip install`), counts confirms vs denies, and suggests promotions for patterns with high confirm counts and zero denies.

## Components

- `.claude-plugin/plugin.json` — hook registration (Bash, Write, Edit matchers)
- `scripts/permission-gate.sh` — tiered evaluation engine (Bash commands), including gate-the-gate for Bash writes at protected paths
- `scripts/gate-config-writes.sh` — gate-the-gate hook (Write/Edit to config files)
- `prompts/permission-evaluate.md` — Tier 2 LLM evaluation prompt template
- `commands/tune.md` — `/tune` command for log-based rule self-tuning
- `tests/test-permission-gate.sh` — tiered evaluation, including the Bash routes to protected paths
- `tests/test-gate-config-writes.sh` — the Write/Edit gate, including its fail-closed paths
- `tests/test-protected-paths-parity.sh` — holds the two copies of the protected-path set identical

## Testing

```bash
for t in plugins/permission-gateway/tests/test-*.sh; do bash "$t"; done
```

Suite sizes are deliberately not quoted here — a hand-written count drifts silently the first time someone adds a case, and a stale number reads as authoritative (see #112 for the same failure with version strings). Run the suites for the current figure.
