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

# Runs the pilot checks of verified/CXX-VERIFICATION-PILOT.md and compares
# each verdict with the expected one: the harnesses on the real sources must
# verify, the same harnesses on a copy with a fixed bug put back
# (verified/cxx/mutants) must fail, the Kani harnesses must give their
# expected verdicts (pos_ verify, neg_ and tool_ fail).
# Logs go to $CXXV_HOME/logs. Exit status: 0 if every verdict is expected.
# Usage: verified/cxx/run.sh [NAME...]   (no name: all)

set -uo pipefail
cd "$(dirname "$0")/../.."
. verified/cxx/env.sh
logs=$CXXV_HOME/logs
mkdir -p "$logs"

# name | expect (pass/fail) | mutant (- for none) | command...
checks=(
  "array-new-root-32|pass|-|verified/cxx/esbmc.sh verified/cxx/harness/array_new.cc --32"
  "array-new-root-64|pass|-|verified/cxx/esbmc.sh verified/cxx/harness/array_new.cc --64"
  "division-error-root-32|pass|-|verified/cxx/esbmc.sh verified/cxx/harness/division_error_root.cc --32"
  "division-error-root-64|pass|-|verified/cxx/esbmc.sh verified/cxx/harness/division_error_root.cc --64"
  "utf8|pass|-|verified/cxx/esbmc.sh verified/cxx/harness/utf_8_to_16.cc --unwind 10 --overflow-check"
  "utf8-mutant|fail|utf-8-to-16-overread|verified/cxx/esbmc.sh verified/cxx/harness/utf_8_to_16.cc --unwind 10"
  "utf8-equiv|pass|-|verified/cxx/esbmc.sh verified/cxx/harness/utf_8_to_16_equiv.cc --unwind 10"
  "utf8-crux|pass|-|env CRUX_HARNESS_FLAGS=-DN=4 verified/cxx/crux.sh verified/cxx/harness/crux_utf_8_to_16.cc utils.cc -Os"
  "utf8-crux-mutant|fail|utf-8-to-16-overread|env CRUX_HARNESS_FLAGS=-DN=3 verified/cxx/crux.sh verified/cxx/harness/crux_utf_8_to_16.cc utils.cc -Os"
  "kani|kani|-|verified/cxx/kani.sh"
)
# Run the counterexample and larger object-level checks by name. The
# pilot results describe the memory and time requirements of the latter.
slow=(
  "external-accounting-lost-update-32|fail:concurrent registration and release preserve both changes|external-accounting-lost-update|verified/cxx/esbmc.sh verified/cxx/harness/external_accounting_threads.cc --32 -DCXXV_WORD_BITS=32 -DTOIT_VERIFIED_CORE --overflow-check"
  "external-accounting-lost-update-64|fail:concurrent registration and release preserve both changes|external-accounting-lost-update|verified/cxx/esbmc.sh verified/cxx/harness/external_accounting_threads.cc --64 -DCXXV_WORD_BITS=64 -DTOIT_VERIFIED_CORE --overflow-check"
  "encoder|pass|-|verified/cxx/esbmc.sh verified/cxx/harness/message_encoder.cc --unwind 3 --unwindsetname N@toit@S@MessageEncoder@encode_array:0:5,N@toit@S@MessageEncoder@encode_map:0:5,N@toit@S@MessageEncoder@write_cardinal:0:11 --overflow-check -DCXXV_NO_WRITE_PASS -DCXXV_COLLECTION=0 -DCXXV_BACKING=0 -DCXXV_ARRAY=1"
  "encoder-mutant|fail|message-encoder-bounds|verified/cxx/esbmc.sh verified/cxx/harness/message_encoder.cc --unwind 3 --unwindsetname N@toit@S@MessageEncoder@encode_array:0:5,N@toit@S@MessageEncoder@encode_map:0:5,N@toit@S@MessageEncoder@write_cardinal:0:11 -DCXXV_NO_WRITE_PASS -DCXXV_COLLECTION=0 -DCXXV_BACKING=0 -DCXXV_ARRAY=1"
  "int-parse|pass|-|verified/cxx/esbmc.sh verified/cxx/harness/int_parse.cc --unwind 2 --unwindsetname primitive_core.cc@N@toit@parse_short_decimal:0:19,int_parse.cc@parse_reference:0:19 --overflow-check -DCXXV_BLOB_KIND=2 -DCXXV_MAX_BLOB=19"
  "int64-to-string|pass|-|verified/cxx/esbmc.sh verified/cxx/harness/int64_to_string.cc --unwind 72 --overflow-check"
  "grow-stack|pass|-|verified/cxx/esbmc.sh verified/cxx/harness/grow_stack.cc --unwind 7 --unwindsetname __memcpy_impl:0:30 --overflow-check -DCXXV_MAX_LENGTH=3 -DCXXV_NEEDED_MAX=3"
  # Not run at all: Frama-C/WP (89 of 96 goals, see the write-up),
  # string_write.cc (ESBMC crashes on it: tool defect T3).
)
if [ $# -gt 0 ]; then checks+=("${slow[@]}"); fi

failures=0
for entry in "${checks[@]}"; do
  IFS='|' read -r name expect mutant cmd <<< "$entry"
  if [ $# -gt 0 ] && [[ " $* " != *" $name "* ]]; then continue; fi
  src=$CXXV_REPO/src
  [ "$mutant" = - ] || src=$(verified/cxx/mutant-src.sh "$mutant")
  start=$(date +%s)
  # shellcheck disable=SC2086
  CXXV_SRC=$src $cmd > "$logs/$name.log" 2>&1
  status=$?
  secs=$(( $(date +%s) - start ))
  if [ "$expect" = kani ]; then
    # Every pos_ harness verified, every neg_/tool_ harness failed.
    bad=$(awk '/^Checking harness/ { h = $3 } /^VERIFICATION:-/ {
             ok = ($2 == "SUCCESSFUL"); pos = (h ~ /::pos_/);
             if (ok != pos) print h }' "$logs/$name.log")
    if [ -z "$bad" ] && grep -q "^Checking harness" "$logs/$name.log"; then verdict=expected; else verdict="UNEXPECTED $bad"; fi
  elif grep -qE "Out of memory|SIGSEGV|PARSING ERROR|esbmc.sh: cannot" "$logs/$name.log"; then
    verdict="TOOL FAILURE"
  elif [[ "$expect" == fail:* ]]; then
    reason=${expect#fail:}
    if [ "$status" -ne 0 ] && grep -Fqx "  $reason" "$logs/$name.log" && grep -Fxq "VERIFICATION FAILED" "$logs/$name.log"; then
      verdict=expected
    else
      verdict=UNEXPECTED
    fi
  elif [ "$expect" = pass ] && [ $status -eq 0 ]; then verdict=expected
  elif [ "$expect" = fail ] && [ $status -ne 0 ]; then verdict=expected
  else verdict=UNEXPECTED
  fi
  [ "$verdict" = expected ] || failures=$((failures + 1))
  printf '%-22s %-5s %6ss  %s\n' "$name" "$expect" "$secs" "$verdict"
done
exit $(( failures > 0 ))
