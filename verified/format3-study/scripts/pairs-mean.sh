#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Mean share (equal weight per benchmark) of opcode pairs or triples over
# the traced benchmarks (logs/trace-*.txt from trace.sh).
# Usage: pairs-mean.sh pairs|triples|opcodes [TOP]
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/format3-study
WHAT=$1
TOP=${2:-40}
BENCHES="richards deltablue pystone json map-set strings gc-stress tison-2k json-decode-30 tasks rpc yield"
cat "$A/logs/trace-opbench.txt" "$A/logs/trace-rpc.txt" "$A/logs/trace-tasks.txt" |
  awk -v what="-- $WHAT" -v benches="$BENCHES" '
    BEGIN { n = split(benches, b, " "); for (i = 1; i <= n; i++) want[b[i]] = 1 }
    /^== dynamic / { cur = $3; sec = ""; next }
    /^-- / { sec = $0; next }
    sec == what && (cur in want) && !((cur, "seen") in done) {
      pct = $2; $1 = ""; $2 = ""; $3 = ""; key = $0; gsub(/^ +/, "", key)
      if (what == "-- opcodes") { key = $4 }
      s[key] += pct; used[cur] = 1
    }
    END { m = 0; for (k in used) m++; for (k in s) printf "%6.2f %s\n", s[k] / m, k }' |
  sort -rn | head -n "$TOP"
