#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The speed tables of README.md (logs/agg-tables.txt).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/s3-ota-soak
S=$A/scripts/bench-agg.sh
{
  echo "## ESP32 hwbench"
  bash "$S" "b1-f1-bench-r1 b2-f1-bench-r2 b1-f1-bench-r3" "b2-f2-bench-r1 b1-f2-bench-r2 b2-f2-bench-r3" earlier-b1-f1-bench-final earlier-b2-f2-bench-final
  echo "## ESP32 perfbench"
  bash "$S" "b1-f1-perf-r1 b2-f1-perf-r2 b1-f1-perf-r3" "b2-f2-perf-r1 b1-f2-perf-r2 b2-f2-perf-r3" earlier-b1-f1-perf-final earlier-b2-f2-perf-final
  echo "## C6 hwbench"
  bash "$S" "c6-f1-bench-r1 c6-f1-bench-r2 c6-f1-bench-r3" "c6-f2-bench-r1 c6-f2-bench-r2 c6-f2-bench-r3" earlier-c6-f1-bench-final earlier-c6-f2-bench-final
  echo "## C6 perfbench"
  bash "$S" "c6-f1-perf-r1 c6-f1-perf-r2 c6-f1-perf-r3" "c6-f2-perf-r1 c6-f2-perf-r2 c6-f2-perf-r3" earlier-c6-f1-perf-final earlier-c6-f2-perf-final
} | tee "$A/logs/agg-tables.txt"
