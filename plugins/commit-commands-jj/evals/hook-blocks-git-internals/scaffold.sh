#!/usr/bin/env bash
# Same throwaway jj repo as hook-blocks-raw-git/scaffold.sh, and the same
# reason for writing the hardening into the sandbox HOME rather than exporting
# it: this script and the agent turn are different processes, and only HOME
# crosses between them. See that file's header, and
# tests/test-eval-scaffold.sh.
set -euo pipefail

JJ_USER="${JJ_USER:-eval}"
JJ_EMAIL="${JJ_EMAIL:-eval@example.com}"

# Write the config ONLY into a throwaway HOME. See the sibling scaffold in
# hook-blocks-raw-git/ for the full reasoning: unconditional, this truncated the
# developer's real ~/.config/jj/config.toml, because `--scaffold` runs this
# script with the real $HOME rather than the sandbox one the header assumes
# (#118). `cat >` does not merge, so aliases and signing config went too.
#
# Skip-with-warning rather than abort: skipping costs at most this run's
# anti-hang hardening, writing costs unrecoverable data.
resolve_existing() {
  d="$1"
  while [ -n "$d" ] && [ "$d" != "/" ] && [ ! -d "$d" ]; do d=$(dirname "$d"); done
  (cd "$d" 2>/dev/null && pwd -P) || printf '%s\n' "$d"
}

conf_base="${XDG_CONFIG_HOME:-$HOME/.config}"
conf_dir="$conf_base/jj"
# Physical paths on both sides: macOS TMPDIR lives under /var/folders, reached
# through a symlink, so an unresolved comparison never matches.
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
