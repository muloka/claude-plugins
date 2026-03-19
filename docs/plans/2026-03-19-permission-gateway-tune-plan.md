# Permission Gateway Tune Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `/tune` slash command in the permission-gateway plugin that scans the decision log, identifies frequently-confirmed commands, and proposes `.local.md` rule promotions — closing the self-tuning feedback loop.

**Architecture:** A slash command (`commands/tune.md`) that instructs Claude to read the log file, normalize commands into patterns, count decisions per pattern, and present promotion suggestions. Claude handles the analysis and `.local.md` writing — the command is a prompt, not a script.

**Tech Stack:** Markdown (command file), Bash (log reading), jq (optional)

**Spec:** `docs/specs/2026-03-18-permission-gateway-and-fan-flames-design.md` (Resolved Question 4, Phase 3)

---

### File Structure

```
plugins/permission-gateway/
├── commands/
│   └── tune.md                    # NEW: slash command
```

---

### Task 1: Create the Tune Command

**Files:**
- Create: `plugins/permission-gateway/commands/tune.md`

- [ ] **Step 1: Create the commands directory**

```bash
mkdir -p plugins/permission-gateway/commands
```

- [ ] **Step 2: Write the command file**

Create `plugins/permission-gateway/commands/tune.md`:

```markdown
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

### Step 2: Normalize Commands into Patterns

For each log line (format: `TIMESTAMP DECISION COMMAND`), extract the command and normalize it into a pattern by keeping only the command prefix — the part that identifies the *type* of command, not the specific arguments.

**Normalization rules:**

| Command | Pattern | Why |
|---------|---------|-----|
| `pip install requests` | `pip install` | Package name varies |
| `pip install flask` | `pip install` | Same pattern |
| `docker run -it ubuntu bash` | `docker run` | Image/flags vary |
| `docker run --rm node:18 npm test` | `docker run` | Same pattern |
| `ssh user@host` | `ssh` | Host varies |
| `npm install express` | `npm install` | Package varies |
| `cargo add serde` | `cargo add` | Crate varies |
| `mv old.txt new.txt` | `mv` | Files vary |
| `htop` | `htop` | No args |
| `sed -i 's/old/new/g' file.txt` | `sed -i` | Pattern/file vary |

**Normalization approach:**

```bash
# Extract command from log, normalize to pattern
# 1. Strip timestamp: cut from 3rd field onward
# 2. Strip decision (APPROVE/DENY/CONFIRM): cut from 2nd field onward
# 3. Take first 1-2 meaningful tokens as the pattern
awk '{
  # Skip timestamp (field 1) and decision (field 2)
  cmd = ""
  for (i=3; i<=NF; i++) cmd = cmd (i>3 ? " " : "") $i

  # Normalize: take command + first subcommand/flag if it looks like one
  split(cmd, parts, " ")
  pattern = parts[1]

  # If second token is a subcommand (not a path/package/flag-value), include it
  if (parts[2] != "" && parts[2] !~ /^[\/~.]/ && parts[2] !~ /^[a-z].*[.\/]/) {
    # Include subcommands like "install", "run", "build", "-i", "-c", "-e"
    if (parts[2] ~ /^(install|add|publish|run|build|test|push|pull|clone|create|delete|stop|start|up|down|-[a-z])$/) {
      pattern = pattern " " parts[2]
    }
  }

  print pattern
}'
```

This is a heuristic — imperfect but good enough. The user reviews suggestions before accepting.

### Step 3: Count Decisions per Pattern

Combine normalization and counting in a single pipeline. For each log line, emit `DECISION PATTERN`, then group by pattern and count each decision type:

```bash
# Single pipeline: normalize + tag with decision + count per pattern
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

This produces a tab-separated table:

```
pip install     42      0       0
docker run      15      2       0
htop            12      0       0
mv              8       1       0
```

Build a summary table from this output:

| Pattern | Confirms | Denies | Approves |
|---------|----------|--------|----------|
| `pip install` | 42 | 0 | 0 |
| `docker run` | 15 | 2 | 0 |
| `htop` | 12 | 0 | 0 |
| `mv` | 8 | 1 | 0 |

### Step 4: Filter Promotion Candidates

A pattern is promotable if:
- Confirmed >= threshold (default 10)
- Never denied (0 denies)
- Not already in `.local.md` approve rules

Patterns with any denies are excluded — if the user denied it even once, it's not safe to auto-approve.

Patterns below threshold are shown as informational (not actionable) so the user can see what's trending.

### Step 5: Present Suggestions

```
🪭 Permission Gateway Tune

Scanned: .claude/permission-gateway.log (1,247 entries)
Threshold: 10+ confirms, 0 denies

Suggested promotions:
  pip install      (42 confirms, 0 denies) → approve?
  htop             (12 confirms, 0 denies) → approve?
  terraform plan    (8 confirms, 0 denies)  → 2 more to qualify

Already in .local.md:
  kubectl get      (approved)

No changes yet. Apply suggestions? [y/n/select]
```

If the user says:
- **y** — write all suggestions to `.local.md`
- **n** — done, no changes
- **select** — let the user pick which ones to promote

### Step 6: Write to .local.md

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
```

- [ ] **Step 3: Verify the command frontmatter is valid**

```bash
head -15 plugins/permission-gateway/commands/tune.md
```

Expected: YAML frontmatter with `description:`, `argument-hint:`, and `allowed-tools:`.

- [ ] **Step 4: Describe the change**

```bash
jj describe -m "feat(permission-gateway): add /tune command for log-based rule promotion"
```

---

### Task 2: Update Permission-Gateway README

**Files:**
- Modify: `plugins/permission-gateway/README.md`

- [ ] **Step 1: Read current README**

```bash
cat plugins/permission-gateway/README.md
```

- [ ] **Step 2: Add tune command section**

Add after the "Decision Logging" section:

```markdown
## Self-Tuning

After accumulating log data, use `/tune` to promote frequently-confirmed commands:

```
/tune                    # scan project log, suggest promotions (threshold: 10)
/tune --threshold 5      # lower threshold
/tune --global           # scan/update user-global rules instead
```

The command scans the log, normalizes commands into patterns (`pip install requests` → `pip install`), counts confirms vs denies, and suggests promotions for patterns with high confirm counts and zero denies.
```

- [ ] **Step 3: Add `/tune` to the Components section**

Add to the components list:

```markdown
- `commands/tune.md` — `/tune` command for log-based rule self-tuning
```

- [ ] **Step 4: Describe the change**

```bash
jj describe -m "feat(permission-gateway): add /tune command and README docs

- /tune scans decision log, suggests .local.md rule promotions
- Normalizes commands into patterns, filters by confirm count and zero denies
- Supports --threshold and --global flags
- Documents self-tuning workflow in README"
```

---

### Task 3: Update Root README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the permission-gateway section of root README**

Find the permission-gateway section and update it.

- [ ] **Step 2: Add tune mention**

Add after the "Self-tuning" line in the permission-gateway section:

```markdown
**Commands:** `/tune` — scan decision log and propose `.local.md` rule promotions
```

- [ ] **Step 3: Update the plugin table**

Change permission-gateway row from `— | —` to `1 | —` (it now has 1 command):

```markdown
| **permission-gateway** | Tiered permission gating — hook-only, zero-config | 1 | — |
```

- [ ] **Step 4: Describe the change**

```bash
jj describe -m "feat(permission-gateway): /tune command, README docs, root README update

- /tune: log-based rule self-tuning command
- Command normalization: pip install requests → pip install
- Threshold filtering: 10+ confirms, 0 denies
- README and root README updated"
```

---

### Task 4: Smoke Test

**Files:**
- No new files — verification only

- [ ] **Step 1: Verify command file exists and has valid frontmatter**

```bash
ls -la plugins/permission-gateway/commands/tune.md
sed -n '1,/^---$/p' plugins/permission-gateway/commands/tune.md | head -15
```

- [ ] **Step 2: Verify README mentions /tune**

```bash
grep -c "tune" plugins/permission-gateway/README.md
```

Expected: at least 3 matches.

- [ ] **Step 3: Verify gate-the-gate covers the .local.md write path**

```bash
# Verify that gate-config-writes.sh would catch writes to permission-gateway.local.md
echo '{"tool_input":{"file_path":".claude/permission-gateway.local.md"}}' | \
  bash plugins/permission-gateway/scripts/gate-config-writes.sh | \
  jq -r '.hookSpecificOutput.permissionDecision'
```

Expected: `ask`

- [ ] **Step 4: Verify root README plugin table**

```bash
grep "permission-gateway" README.md
```

Expected: shows `1 | —` for commands.

- [ ] **Step 5: Create a test log and verify the normalization concept**

```bash
# Create a temporary test log
TMPLOG=$(mktemp)
cat > "$TMPLOG" <<'LOG'
2026-03-19T04:15:23Z APPROVE npm test
2026-03-19T04:15:24Z CONFIRM pip install requests
2026-03-19T04:15:25Z CONFIRM pip install flask
2026-03-19T04:15:26Z CONFIRM pip install pandas
2026-03-19T04:15:27Z CONFIRM docker run -it ubuntu
2026-03-19T04:15:28Z DENY sudo rm /etc/hosts
2026-03-19T04:15:29Z CONFIRM htop
2026-03-19T04:15:30Z CONFIRM pip install numpy
LOG

# Test normalization: extract patterns from CONFIRM lines
awk '$2 == "CONFIRM" {
  cmd = ""
  for (i=3; i<=NF; i++) cmd = cmd (i>3 ? " " : "") $i
  split(cmd, parts, " ")
  pattern = parts[1]
  if (parts[2] ~ /^(install|add|publish|run|build|test|push|pull|clone|create|delete|stop|start|up|down|-[a-z])$/) {
    pattern = pattern " " parts[2]
  }
  print pattern
}' "$TMPLOG" | sort | uniq -c | sort -rn

rm "$TMPLOG"
```

Expected output:
```
   4 pip install
   1 htop
   1 docker run
```

- [ ] **Step 6: Final describe**

```bash
jj describe -m "feat(permission-gateway): /tune command for log-based rule self-tuning

- Scans .claude/permission-gateway.log for promotion candidates
- Normalizes commands into patterns (pip install requests → pip install)
- Filters: threshold confirms (default 10), zero denies
- Presents suggestions, user confirms before writing to .local.md
- Supports --threshold N and --global flags
- One-way ratchet still applies: promoted rules can't override hardcoded deny
- README and root README updated"
```
