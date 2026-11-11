#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Runs VeriFast on one annotated file and reports the verdict and the time.
#
# Usage: vf.sh [VERIFAST-OPTIONS...] FILE
#   The options are passed through (e.g. -target ILP32, -disable_overflow_check).
#   Always passes -c (no link check: the files are not whole programs).

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

start=$(date +%s%N)
"$VERIFAST" -c "$@"
status=$?
end=$(date +%s%N)
ms=$(( (end - start) / 1000000 ))
printf 'vf.sh: exit %d, %d.%03d s: %s\n' "$status" $((ms / 1000)) $((ms % 1000)) "$*"
exit $status
