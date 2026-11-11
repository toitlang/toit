#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

# Runs the images of an EC618 envelope on the EC618 VM library under QEMU's
# mps2-an385 (CMakeLists.txt builds the harness) and exits with the VM's
# exit code (0: done; harness.cc, startup.c and gen-stubs.sh list the
# others).
#
# Usage: run.sh HARNESS-ELF ENVELOPE [QEMU-ARGS...]
#   QEMU: qemu-system-arm (default: the one on the PATH).
#   TOIT: the host SDK's toit (default: build/host/sdk/bin/toit).
#   ICOUNT: -icount shift (default 0: one instruction per virtual
#     nanosecond, so the programs' clock counts instructions).
#   TIMEOUT: seconds of host time (default 600).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ELF="${1:?harness elf}"
ENVELOPE="${2:?envelope}"
shift 2
QEMU="${QEMU:-qemu-system-arm}"
TOIT="${TOIT:-$REPO/build/host/sdk/bin/toit}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$TOIT" run --project-root "$REPO/tools" "$HERE/extension.toit" -- \
    --envelope "$ENVELOPE" --out "$WORK/extension.bin" >&2
timeout "${TIMEOUT:-600}" "$QEMU" -M mps2-an385 -cpu cortex-m3 \
    -nographic -monitor none -serial none \
    -semihosting-config enable=on,target=native \
    -icount shift="${ICOUNT:-0}" \
    -kernel "$ELF" \
    -device loader,file="$WORK/extension.bin",addr=0x21000000 \
    "$@"
