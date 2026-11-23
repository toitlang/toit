#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
set -euo pipefail
source "$(dirname "$0")/../env.sh"
case "$1" in
  LP64) machdep=gcc_x86_64 ;;
  ILP32) machdep=x86_32 ;;
  *) exit 2 ;;
esac
export PATH="$CXXV_HOME/tools/opam/root/cxxv/bin:$PATH"
work=$(mktemp -d "$ACXX_WORK/records-wp.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"
log="$ACXX_WORK/logs/records-wp-$1.log"
frama-c -machdep "$machdep" -wp -wp-rte -wp-prover alt-ergo -wp-timeout 15 \
  -wp-cache none -wp-report-json goals.json "$ANNOTATED_DIR/loader/records.c" > "$log" 2>&1 || { cat "$log"; exit 1; }
python3 - "$1" "$log" <<'PY'
import json
import sys
from pathlib import Path
goals = json.loads(Path("goals.json").read_text())
properties = {g["property"] for g in goals}
required = {"v2_validate_records_ensures", "v2_validate_records_terminates",
            "v2_validate_records_loop_variant", "v2_validate_records_assigns",
            "v2_validate_records_loop_invariant_5", "v2_record_entry_requires",
            "v2_check_header_requires_2", "v2_next_header_requires_3"}
missing = sorted(required - properties)
failed = [g["goal"] for g in goals if g["verdict"] != "valid"]
if missing or failed or "Memory model hypotheses" in Path(sys.argv[2]).read_text():
    sys.exit(f"FAIL  v2-table-loop/{sys.argv[1]}: see {sys.argv[2]} (unproved {failed}, missing {missing})")
print(f"ok    v2-table-loop/{sys.argv[1]}: {len(goals)} obligations proved")
PY
cp goals.json "$ACXX_WORK/logs/records-wp-$1.json"
