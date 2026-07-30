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

**Known limit — this is shape matching, not argument resolution.** It reasons about the text of a command rather than the files that command would touch, and it cannot be proved exhaustive. Three review rounds each found a new class that slipped through: relative and `cd` path forms, then quoted directory names and `cp -t DEST src`, then command substitution — and a sweep immediately after the third fix found ANSI-C quoting (`$'\056claude/...'`) still open. Constructs it does not recognise specifically (`pushd`, a subshell, a `cd` via variable) fall through to the Tier-2 catch-all, which still asks: weaker wording, not a bypass. #123 remains open for resolving arguments properly.

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
