#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Inclusive Ir per iteration of selected functions (slow paths by cause)
# in the callgrind outputs of cgrun.sh: (Ir(N run) - Ir(0 run)) / N.
# Usage: cgfuncs.sh TAG FORMAT BENCH N    (prints "per-iteration function")
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/format3-study
TAG=$1; F=$2; B=$3; N=$4
FUNCS='toit_v2_primitive|cxx_primitive_rest|step::slow|ensure_room_all|op_try_v|ret_try_v|op_non_local_return_v|unwind_resume_v|move_records|toit_v2_grow_stack|op_hash_find_v|Scavenger::scavenge|ObjectHeap::gc|v2_task_transfer|toit_v2_run|machine::run|step::run_loop|v2_primitive_failed|Primitive_|Interpreter::run\(\)'
incl() {  # file
  callgrind_annotate --inclusive=yes --threshold=100 "$1" 2>/dev/null | grep ' \[/' |
    sed -nE 's/^ *([0-9,]+) \([^)]*\) +([^ ]*\/[^:]*|\?\?\?):(.*) \[\/.*/\1\t\3/p' | tr -d ',' |
    awk -F'\t' '{ s[$2] += $1 } END { for (k in s) print k "\t" s[k] }' | LC_ALL=C sort -t"$(printf '\t')" -k1,1
}
TAB=$(printf '\t')
LC_ALL=C join -t"$TAB" -a1 -e 0 -o 0,1.2,2.2 <(incl "$A/logs/cg/run-$TAG-f$F-$B.out") <(incl "$A/logs/cg/run-$TAG-f$F-$B-0.out") |
  grep -E "^[^$TAB]*($FUNCS)$TAB" | awk -F"$TAB" -v n="$N" '{ printf "%10.0f  %s\n", ($2 - $3) / n, $1 }' | sort -rn
