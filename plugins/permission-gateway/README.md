# permission-gateway

Tiered permission gateway for Claude Code — auto-approves safe commands, blocks dangerous ones, confirms risky operations, and LLM-evaluates everything else.

## Why

When running 3-5 subagents in parallel (e.g., fan-flames), each making 20+ tool calls, you either pre-approve everything (dangerous) or get 60+ confirmation prompts (kills parallelism). Permission gateway is the middle ground: ~85% auto-approved, ~10% auto-denied, ~5% human-confirmed.

## How It Works

```
Tool call → Gate-the-Gate → Deny (immutable) → .local.md → Confirm → Approve → Tier 2 LLM
```

Seven evaluation stages, one exit per command. Each decision is logged for rule self-tuning.

| Tier | Action | Examples |
|------|--------|---------|
| **Gate-the-Gate** | Confirms config writes | Write/Edit to `*permission-gateway*` files |
| **Deny** | Blocked, never runs | `rm -rf /`, `sudo`, `eval`, `dd`, `kill -9` |
| **Confirm** | Human sees prompt | `npm publish`, `ssh`, `mv`, `docker run`, `xargs` |
| **Approve** | Silent, no prompt | `ls`, `npm test`, `jj log`, `cargo build`, `grep` |
| **Tier 2** | LLM evaluates, then human confirms | Unknown commands |

## Security

**One-way ratchet:** Hardcoded deny runs before `.local.md` rules. No override can loosen a deny — the deny tier is an immutable floor. This prevents prompt injection attacks where malicious content instructs Claude to write `.local.md` rules promoting dangerous commands.

**Gate the gate:** Writes to files matching `permission-gateway` trigger a human confirmation prompt via a separate Write/Edit hook (`gate-config-writes.sh`). The injection attempt is caught before the file is modified.

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
- `scripts/permission-gate.sh` — tiered evaluation engine (Bash commands)
- `scripts/gate-config-writes.sh` — gate-the-gate hook (Write/Edit to config files)
- `prompts/permission-evaluate.md` — Tier 2 LLM evaluation prompt template
- `commands/tune.md` — `/tune` command for log-based rule self-tuning
- `tests/test-permission-gate.sh` — 124 tests

## Testing

```bash
bash plugins/permission-gateway/tests/test-permission-gate.sh
```
