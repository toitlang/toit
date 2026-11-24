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
report="$ACXX_WORK/logs/records-wp-$1.json"
frama-c -machdep "$machdep" -wp -wp-rte -wp-prover alt-ergo -wp-timeout 15 \
  -wp-cache none -wp-report-json goals.json "$ANNOTATED_DIR/loader/records.c" > "$log" 2>&1 || { cat "$log"; exit 1; }
cp goals.json "$report"
required=(
  v2_validate_records_ensures v2_validate_records_terminates
  v2_validate_records_loop_variant v2_validate_records_assigns
  v2_validate_records_loop_invariant_5 v2_record_entry_requires
  v2_check_header_requires_2 v2_next_header_requires_3
)
wp_report "v2-table-loop/$1" "$report" "$log" "${required[@]}"
