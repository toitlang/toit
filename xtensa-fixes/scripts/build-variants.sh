#!/usr/bin/env bash
# Builds the device library variants used for the exposure scan:
#   o3      as the tree builds it (core opt 3, toit_spec z, no LTO: Cargo
#           drops `lto` for staticlib+rlib crate types)
#   os, oz  core opt s / z
#   o3-lto, oz-lto  fat LTO (cargo rustc --crate-type staticlib)
# Usage: build-variants.sh <worktree>
set -euo pipefail
WT=$1
S=/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes/scripts/build-devlib.sh
OPT=3 bash "$S" "$WT" o3
OPT=s bash "$S" "$WT" os
OPT=z bash "$S" "$WT" oz
OPT=3 LTO=1 bash "$S" "$WT" o3-lto
OPT=z LTO=1 bash "$S" "$WT" oz-lto
