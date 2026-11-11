#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Runs VeriFast on a Rust file, with the toolchain of
# install-tools.sh verifast-rust. Usage: vf-rust.sh [OPTIONS...] FILE.rs

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
export RUSTUP_HOME="$ACXX_HOME/tools/rustup" CARGO_HOME="$ACXX_HOME/tools/cargo"
start=$(date +%s%N)
"$VERIFAST" "$@"
status=$?
end=$(date +%s%N)
ms=$(( (end - start) / 1000000 ))
printf 'vf-rust.sh: exit %d, %d.%03d s: %s\n' "$status" $((ms / 1000)) $((ms % 1000)) "$*"
exit $status
