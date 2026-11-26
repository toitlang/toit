#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Host instruction counts (callgrind Ir) per iteration of the run-time
# benchmarks on the release host build, format 1 and 2 (trusted format 2
# runs on the verified loop, as the device's first-party containers):
#   cgbench.toit: richards deltablue pystone json calls (1 iteration - 0)
#   taskbench.toit: tasks (1000) yield (2000) rpc (200)
# Per iteration = (Ir(N) - Ir(0)) / N. The N run's callgrind output stays
# in logs/cg/run-TAG-fF-BENCH.out (callgrind_annotate for the functions).
# Usage: cgrun.sh TAG [FORMATS] [BENCHES]     Output: logs/cgrun-TAG.txt
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a8868e80a23e89460}
A=/home/flo/work/opentoit-sandbox-artifacts/format3-study
BIN=${BIN:-$WT/build/host/sdk/lib/toit/bin}
export TMPDIR=$WT/build/tmp
TAG=$1
FORMATS=${2:-1 2}
BENCHES=${3:-richards deltablue pystone json calls tasks yield rpc}
OUT=$A/logs/cgrun-$TAG.txt
mkdir -p "$A/logs/cg" "$TMPDIR/snap"
: > "$OUT"
ir_of() {  # out-file
  sed -n 's/^summary: //p; s/^totals: //p' "$1" | head -1
}
for f in $FORMATS; do
  for b in $BENCHES; do
    case $b in
      tasks) prog=taskbench; n=1000 ;; yield) prog=taskbench; n=2000 ;; rpc) prog=taskbench; n=200 ;;
      *) prog=cgbench; n=1 ;;
    esac
    snap=$TMPDIR/snap/$prog-$TAG-f$f.snap
    if [ ! -f "$snap" ]; then
      (cd "$A/progs/host" && TOIT_V2_UNCHECKED=1 "$BIN/toit.compile" -Xbytecode_format="$f" -w "$snap" "$A/progs/host/$prog.toit") || exit 1
    fi
    o0=$A/logs/cg/run-$TAG-f$f-$b-0.out
    o1=$A/logs/cg/run-$TAG-f$f-$b.out
    valgrind --tool=callgrind --callgrind-out-file="$o0" "$BIN/toit.run" "$snap" "$b" 0 > "$o0.log" 2>&1
    valgrind --tool=callgrind --callgrind-out-file="$o1" "$BIN/toit.run" "$snap" "$b" "$n" > "$o1.log" 2>&1
    i0=$(ir_of "$o0"); i1=$(ir_of "$o1")
    echo "$TAG f$f $b n=$n per-iter $(( (i1 - i0) / n )) (Ir $i0 / $i1)" | tee -a "$OUT"
  done
done
