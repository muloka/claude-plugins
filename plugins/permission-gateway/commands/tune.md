---
description: "Scan permission-gateway log and suggest rule promotions for .local.md"
argument-hint: "[--threshold N] [--global]"
allowed-tools:
  - Bash(cat:*)
  - Bash(sort:*)
  - Bash(uniq:*)
  - Bash(grep:*)
  - Bash(awk:*)
  - Bash(wc:*)
  - Bash(head:*)
  - Bash(tail:*)
  - Bash(sed:*)
  - Read
  - Write
  - Edit
---

## Permission Gateway Tune

Scan the decision log and suggest rule promotions for `.local.md`.

### Arguments

- `--threshold N` — minimum number of confirms before suggesting promotion (default: 10)
- `--global` — scan and update `~/.claude/permission-gateway.local.md` instead of project-level

### Step 1: Locate and Read the Log

Find the log file:

```bash
# Project-level log (default)
cat .claude/permission-gateway.log 2>/dev/null

# If --global flag, use user-global log
cat ~/.claude/permission-gateway.log 2>/dev/null
```

If no log file exists, report: "No permission-gateway log found. The log is created automatically when permission-gateway is installed and commands are evaluated. Run some commands first, then try again."

### Step 2: Analyze the Log

For each log line (format: `TIMESTAMP DECISION COMMAND`), extract the command and normalize it into a pattern by keeping only the command prefix — the part that identifies the *type* of command, not the specific arguments.

**Normalization rules:**

| Command | Pattern | Why |
|---------|---------|-----|
| `pip install requests` | `pip install` | Package name varies |
| `pip install flask` | `pip install` | Same pattern |
| `docker run -it ubuntu bash` | `docker run` | Image/flags vary |
| `ssh user@host` | `ssh` | Host varies |
| `npm install express` | `npm install` | Package varies |
| `cargo add serde` | `cargo add` | Crate varies |
| `mv old.txt new.txt` | `mv` | Files vary |
| `htop` | `htop` | No args |
| `sed -i 's/old/new/g' file.txt` | `sed -i` | Pattern/file vary |

**Combined normalization + counting pipeline:**

```bash
awk '{
  decision = $2
  cmd = ""
  for (i=3; i<=NF; i++) cmd = cmd (i>3 ? " " : "") $i

  split(cmd, parts, " ")
  pattern = parts[1]
  if (parts[2] != "" && parts[2] !~ /^[\/~.]/ && parts[2] !~ /^[a-z].*[.\/]/) {
    if (parts[2] ~ /^(install|add|publish|run|build|test|push|pull|clone|create|delete|stop|start|up|down|-[a-z])$/) {
      pattern = pattern " " parts[2]
    }
  }

  key = pattern
  if (decision == "CONFIRM") confirms[key]++
  if (decision == "DENY") denies[key]++
  if (decision == "APPROVE") approves[key]++
  seen[key] = 1
}
END {
  for (k in seen) {
    printf "%s\t%d\t%d\t%d\n", k, confirms[k]+0, denies[k]+0, approves[k]+0
  }
}' .claude/permission-gateway.log | sort -t$'\t' -k2 -rn
```

This is a heuristic — imperfect but good enough. The user reviews suggestions before accepting.

Build a summary table from the output:

| Pattern | Confirms | Denies | Approves |
|---------|----------|--------|----------|
| `pip install` | 42 | 0 | 0 |
| `docker run` | 15 | 2 | 0 |
| `htop` | 12 | 0 | 0 |

### Step 3: Filter Promotion Candidates

A pattern is promotable if:
- Confirmed >= threshold (default 10)
- Never denied (0 denies)
- Not already in `.local.md` approve rules

Patterns with any denies are excluded — if the user denied it even once, it's not safe to auto-approve.

Patterns below threshold are shown as informational (not actionable) so the user can see what's trending.

### Step 4: Present Suggestions

```
🪭 Permission Gateway Tune

Scanned: .claude/permission-gateway.log (1,247 entries)
Threshold: 10+ confirms, 0 denies

Suggested promotions:
  pip install      (42 confirms, 0 denies) → approve?
  htop             (12 confirms, 0 denies) → approve?

Trending (below threshold):
  terraform plan    (8 confirms, 0 denies)  → 2 more to qualify

Not promoted (has denies):
  docker run       (15 confirms, 2 denies)

Already in .local.md:
  kubectl get      (approved)

No changes yet. Apply suggestions? [y/n/select]
```

If the user says:
- **y** — write all suggestions to `.local.md`
- **n** — done, no changes
- **select** — let the user pick which ones to promote

### Step 5: Write to .local.md

If the user approves, update the `.local.md` file:

**If file doesn't exist:** Create it with frontmatter:

```yaml
---
rules:
  approve:
    - "pip install"
    - "htop"
---

## Auto-tuned rules
Rules promoted by `/tune` based on confirmation frequency.
```

**If file exists with rules:** Parse existing frontmatter, merge new approve rules, write back. Do NOT remove existing rules — only add.

**If file exists without approve section:** Add the approve section to the existing rules.

After writing, confirm:

```
✅ Added 2 rules to .claude/permission-gateway.local.md:
  - "pip install" (approve)
  - "htop" (approve)

These commands will now be auto-approved in this project.
```

### Important Notes

- **One-way ratchet still applies.** Promoted rules go into `.local.md` approve section. They can't override hardcoded deny — the ratchet ensures this.
- **Gate-the-gate fires.** Writing to `permission-gateway.local.md` triggers the Write hook confirmation even though `allowed-tools` includes `Write` — PreToolUse hooks fire regardless of tool allowlisting. The user confirms the write, which is expected here.
- **Review, don't blindly accept.** The tune command presents suggestions — the user decides. Never auto-write without confirmation.
- **Denies are informational.** If a pattern has denies, mention it but don't suggest promotion: "docker run (15 confirms, 2 denies) — not promoted due to denies"
