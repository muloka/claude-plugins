#!/usr/bin/env bash
# Same throwaway jj repo as hook-blocks-raw-git/scaffold.sh, and the same
# reason for writing the hardening into the sandbox HOME rather than exporting
# it: this script and the agent turn are different processes, and only HOME
# crosses between them. See that file's header, and
# tests/test-eval-scaffold.sh.
set -euo pipefail

JJ_USER="${JJ_USER:-eval}"
JJ_EMAIL="${JJ_EMAIL:-eval@example.com}"

conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/jj"
mkdir -p "$conf_dir"
cat > "$conf_dir/config.toml" <<TOML
[user]
name = "$JJ_USER"
email = "$JJ_EMAIL"

[ui]
paginate = "never"
editor = "true"
TOML

# Colocated, unlike the sibling scaffold: this case's prompt reads the git
# directory directly, and a plain `jj git init` keeps the git backend inside
# .jj/ so there is nothing at the work-tree root to read. Without colocation
# the without-arm of the ablation fails on a missing file, which scores 0 for a
# reason that has nothing to do with the hook — the delta would then be real
# but would not demonstrate the counterfactual. Colocated, the without-arm
# genuinely reads `ref: refs/heads/main` and the with-arm is denied, so the
# delta measures the wall and not the sandbox (#103).
jj git init --colocate . >/dev/null 2>&1
printf 'alpha\n' > notes.txt
