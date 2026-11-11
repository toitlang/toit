#!/usr/bin/env bash
# Run a snapshot under --untrusted on the normal and the ASan/UBSan build.
# Filters the one benign UBSan line (primitive.h null member call).
# Usage: run-both.sh <snapshot> [extra toit.run args...]
set -u
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a34c2fa11930f607a
HOST="$WT/build/host/sdk/lib/toit/bin/toit.run"
ASAN="$WT/build/asan/sdk/lib/toit/bin/toit.run"
SNAP="$1"; shift || true
FILTER='primitive\.h'
echo "=== NORMAL build ==="
"$HOST" --untrusted "$@" "$SNAP" 2>&1 | grep -v "$FILTER"
echo "   [normal exit ${PIPESTATUS[0]}]"
echo "=== ASAN/UBSAN build ==="
ASAN_OPTIONS=detect_leaks=false:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  "$ASAN" --untrusted "$@" "$SNAP" 2>&1 | grep -v "$FILTER"
echo "   [asan exit ${PIPESTATUS[0]}]"
