#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The experiment tables of README.md (logs/experiments.txt): single sessions
# of the variant builds next to f1 and f2.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed-2
T=$A/scripts/bench-table.sh
{
  echo "## ESP32 hwbench: f1, f2, f2old, f2o3, f2nosplitl"
  bash "$T" b1-f1-bench-r1 b2-f2-bench-r1 b1-f2old-bench-r1 b2-f2o3-bench-r1 b1-f2nosplitl-bench-r1
  echo "## ESP32 perfbench: f1, f2, f2old, f2o3, f2nosplitl"
  bash "$T" b1-f1-perf-r3 b2-f2-perf-r3 b1-f2old-perf-r1 b2-f2o3-perf-r1 b2-f2nosplitl-perf-r1
  echo "## C6 hwbench: f1, f2, f2cold, f2nosplit"
  bash "$T" c6-f1-bench-r1 c6-f2-bench-r1 c6-f2cold-bench-r1 c6-f2nosplit-bench-r1
  echo "## C6 perfbench: f1, f2, f2cold, f2nosplit"
  bash "$T" c6-f1-perf-r1 c6-f2-perf-r1 c6-f2cold-perf-r1 c6-f2nosplit-perf-r1
} | tee "$A/logs/experiments.txt"
