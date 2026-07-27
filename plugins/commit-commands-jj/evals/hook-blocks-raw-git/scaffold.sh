#!/usr/bin/env bash
# Build a throwaway jj repo for the case. Hardened per netresearch's MIT
# pattern: paginate=never and editor=true, so an accidental interactive
# invocation no-ops instead of hanging the run.
#
# The hardening has to land in the sandbox HOME, not in this process's
# environment. The CLI spawns this script with a fixed env whitelist and runs
# the agent turn in a SEPARATE process, so an `export JJ_CONFIG=...` here dies
# with the scaffold and the turn never sees it — and jj does not auto-discover
# a config file sitting next to the work tree. HOME is what the two processes
# share (the turn additionally gets XDG_CONFIG_HOME=$HOME/.config), so jj's
# user config inside that throwaway home is the channel that actually crosses.
# Writing it there also keeps it out of the work tree, which the CLI diffs
# before and after the turn. Covered by tests/test-eval-scaffold.sh.
set -euo pipefail

# Not on the scaffold's env whitelist either — so these resolve to the
# defaults, and the config below is what actually gives the turn an identity.
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
