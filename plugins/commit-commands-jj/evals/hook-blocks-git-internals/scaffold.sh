#!/usr/bin/env bash
set -euo pipefail
export JJ_USER="${JJ_USER:-eval}"
export JJ_EMAIL="${JJ_EMAIL:-eval@example.com}"
mkdir -p .jjconfig
cat > .jjconfig/config.toml <<'TOML'
[ui]
paginate = "never"
editor = "true"
TOML
export JJ_CONFIG="$PWD/.jjconfig/config.toml"
jj git init . >/dev/null 2>&1
printf 'alpha\n' > notes.txt
