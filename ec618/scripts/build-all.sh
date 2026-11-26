#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Builds the EC618 firmware configurations of the worktree, one log each.
# Usage: build-all.sh [NAME...]   (default: all)
#   f1        format 1, C++ interpreter (build/ec618)
#   f2        format 2, core at opt 3, no C++ interpreter (build/ec618-f2)
#   f2s       the same at Rust opt-level s
#   f2z       the same at Rust opt-level z
#   f2nv      f2 without the verifier
#   f2cxx     format 2 with the C++ interpreter still linked
set -u
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a6c88832d90141abe
LOGS=/home/flo/work/opentoit-sandbox-artifacts/ec618/logs
mkdir -p "$LOGS"
cd "$WT"
export IGNORE_SUBMODULE=1 IDF_PATH="$WT/third_party/esp-idf" CCACHE_BASEDIR="$WT" CCACHE_NOHASHDIR=1
NAMES=("$@")
[ ${#NAMES[@]} -gt 0 ] || NAMES=(f1 f2 f2s f2z f2nv f2cxx)
status=0
for n in "${NAMES[@]}"; do
  case "$n" in
    f1) args=(EC618_BUILD_DIR=build/ec618) ;;
    f2) args=(EC618_BYTECODE_FORMAT=2 EC618_BUILD_DIR=build/ec618-f2) ;;
    f2s) args=(EC618_BYTECODE_FORMAT=2 EC618_RUST_OPT_LEVEL=s EC618_BUILD_DIR=build/ec618-f2s) ;;
    f2z) args=(EC618_BYTECODE_FORMAT=2 EC618_RUST_OPT_LEVEL=z EC618_BUILD_DIR=build/ec618-f2z) ;;
    f2nv) args=(EC618_BYTECODE_FORMAT=2 EC618_VERIFIER=OFF EC618_BUILD_DIR=build/ec618-f2nv) ;;
    f2cxx) args=(EC618_BYTECODE_FORMAT=2 EC618_CXX_INTERPRETER=ON EC618_BUILD_DIR=build/ec618-f2cxx) ;;
    *) echo "unknown: $n"; exit 2 ;;
  esac
  if make ec618 "${args[@]}" > "$LOGS/build-$n.log" 2>&1; then
    echo "$n: ok"
  else
    echo "$n: FAILED (see $LOGS/build-$n.log)"
    status=1
  fi
done
exit $status
