#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
test_binary=$(mktemp /tmp/toit-rp2040-update-test.XXXXXX)
trap 'rm -f "$test_binary"' EXIT
cc -std=c11 -Wall -Wextra -Werror -g -fsanitize=address,undefined \
  -I"$root/toolchains/rp2040" "$root/toolchains/rp2040/update.c" \
  "$root/tools/rp2040/tests/update-test.c" -o "$test_binary"
# The sandbox uses ptrace, which LeakSanitizer cannot run under. The test uses
# static storage; retain address and undefined-behavior checks.
ASAN_OPTIONS=detect_leaks=0 "$test_binary"

cc -std=c11 -Wall -Wextra -Werror -g -fsanitize=address,undefined \
  -DTOIT_RECOVERY_STDIO_HOST_TEST \
  -I"$root/toolchains/rp2040" -I"$root/tools/rp2040/tests" \
  "$root/toolchains/rp2040/recovery-stdio.c" \
  "$root/tools/rp2040/tests/recovery-stdio-test.c" -o "$test_binary"
ASAN_OPTIONS=detect_leaks=0 "$test_binary"

# Exercise the exact native allocator source used by the RP2040 VM.
cc -std=c11 -Wall -Wextra -Werror -Wno-sign-compare -Wno-unused-parameter \
  -g -O1 -fsanitize=address,undefined \
  -I"$root/src/third_party/dartino" \
  "$root/src/third_party/dartino/cmpctmalloc.c" \
  "$root/tools/rp2040/tests/heap-test.c" -o "$test_binary"
ASAN_OPTIONS=detect_leaks=0 "$test_binary"

# CI installs multilib; this also exercises the Pico's 32-bit header layout.
if [[ "${TOIT_RP2040_TEST_32_BIT:-0}" == 1 ]]; then
  cc -m32 -std=c11 -Wall -Wextra -Werror -Wno-sign-compare -Wno-unused-parameter \
    -g -O1 -fsanitize=address,undefined \
    -I"$root/src/third_party/dartino" \
    "$root/src/third_party/dartino/cmpctmalloc.c" \
    "$root/tools/rp2040/tests/heap-test.c" -o "$test_binary"
  ASAN_OPTIONS=detect_leaks=0 "$test_binary"
fi
