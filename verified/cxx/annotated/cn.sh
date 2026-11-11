#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Runs CN (installed by install-tools.sh cn) on a C file: `cn verify`.
# Usage: cn.sh FILE [CN OPTIONS...]

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
export OPAMROOT="$ACXX_HOME/tools/opam-cn"
export OPAM_SWITCH_PREFIX="$OPAMROOT/cn"
export PATH="$OPAM_SWITCH_PREFIX/bin:$PATH"
file="$1"; shift
start=$(date +%s%N)
cn verify "$file" "$@"
status=$?
end=$(date +%s%N)
ms=$(( (end - start) / 1000000 ))
printf 'cn.sh: exit %d, %d.%03d s: %s\n' "$status" $((ms / 1000)) $((ms % 1000)) "$file $*"
exit $status
