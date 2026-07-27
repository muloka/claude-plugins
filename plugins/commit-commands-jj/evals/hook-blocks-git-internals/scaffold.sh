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

jj git init . >/dev/null 2>&1
printf 'alpha\n' > notes.txt
