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

# Write the config ONLY into a throwaway HOME.
#
# This used to be unconditional, and it truncated the developer's real
# ~/.config/jj/config.toml (#118). `cat >` does not merge — identity, aliases,
# templates and signing config all went, with no backup. It surfaced when a
# change came out authored eval@example.com and reached a pushed PR.
#
# The header above assumes $HOME is the CLI's sandbox home. `--scaffold` breaks
# that assumption: the CLI prints "runs each case's scaffold_script as you", and
# "as you" includes the real $HOME. The scaffold's CWD *is* sandboxed, so the
# `jj git init .` below is harmless; HOME is not sandboxed at all.
#
# So write only when the target sits under the temp root, and otherwise skip
# with a warning. Skipping is the fail-safe direction: it costs at most this
# run's anti-hang hardening, while writing costs data that cannot be recovered.
# Aborting was considered and rejected — it would break every sweep over a
# protection the run may not even need.
#
# NOTE: when the skip fires, the turn is NOT getting this hardening — a real
# $HOME here means the scaffold and the turn do not share one, so the channel
# described above cannot be carrying anything either. Tracked in #118.
resolve_existing() {
  d="$1"
  while [ -n "$d" ] && [ "$d" != "/" ] && [ ! -d "$d" ]; do d=$(dirname "$d"); done
  (cd "$d" 2>/dev/null && pwd -P) || printf '%s\n' "$d"
}

conf_base="${XDG_CONFIG_HOME:-$HOME/.config}"
conf_dir="$conf_base/jj"
# Physical paths on both sides: macOS TMPDIR lives under /var/folders, which is
# reached through a symlink, so an unresolved comparison never matches.
tmp_real=$(resolve_existing "${TMPDIR:-/tmp}")
conf_real=$(resolve_existing "$conf_base")

case "$conf_real/" in
  "$tmp_real"/*)
    mkdir -p "$conf_dir"
    cat > "$conf_dir/config.toml" <<TOML
[user]
name = "$JJ_USER"
email = "$JJ_EMAIL"

[ui]
paginate = "never"
editor = "true"
TOML
    ;;
  *)
    printf 'scaffold: %s is not under the temp root %s — refusing to write jj config there (#118).\n' \
      "$conf_dir" "$tmp_real" >&2
    ;;
esac

jj git init . >/dev/null 2>&1
printf 'alpha\n' > notes.txt
