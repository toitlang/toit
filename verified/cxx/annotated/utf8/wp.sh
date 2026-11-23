#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.

# Verify the readable-slice contract on the implementation included by utils.cc.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
case "$1" in
  LP64) machdep=gcc_x86_64 ;;
  ILP32) machdep=x86_32 ;;
  *) exit 2 ;;
esac

export PATH="$CXXV_HOME/tools/opam/root/cxxv/bin:$PATH"
command -v frama-c > /dev/null || { echo 'Frama-C is required (verified/cxx/install-tools.sh framac)'; exit 1; }
work=$(mktemp -d "$ACXX_WORK/utf8-wp.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"
log="$ACXX_WORK/logs/utf8-wp-$1.log"
# Aliased tables keep WP from assuming that the input is separate from them.
frama-c -machdep "$machdep" -wp -wp-rte -wp-model Bytes \
  -wp-alias-vars UTF_8_STATE_TABLE,UTF_8_STATE_TABLE_32,MALFORMED_TABLE \
  -wp-fct utf8_is_valid,check_utf8_contract,encoder_string_prefix -wp-prover alt-ergo -wp-timeout 15 \
  -wp-cache none -wp-report-json goals.json "$ANNOTATED_DIR/utf8/validator.c" > "$log" 2>&1 || { cat "$log"; exit 1; }

# WP's exit code alone allows unproved goals. Also require the function frame,
# the call preconditions, and the range check on the full-word read.
python3 - "$1" "$log" <<'PY'
import json
import sys
from pathlib import Path

target, log = sys.argv[1:]
goals = json.loads(Path("goals.json").read_text())
properties = {g["property"] for g in goals}
required = {"utf8_is_valid_assigns", "utf8_is_valid_requires", "utf8_is_valid_requires_2",
            "memcpy_requires_valid_src", "utf8_is_valid_assert_rte_mem_access",
            "utf8_is_valid_terminates", "check_utf8_contract_assigns",
            "encoder_string_prefix_ensures", "encoder_string_prefix_ensures_2",
            "encoder_string_prefix_ensures_3", "encoder_string_prefix_ensures_4",
            "encoder_string_prefix_assert_rte_mem_access", "encoder_string_prefix_assigns",
            "encoder_string_prefix_loop_variant", "encoder_string_prefix_loop_invariant_2"}
failed = [g["goal"] for g in goals if g["verdict"] != "valid"]
if failed or required - properties or "Memory model hypotheses" in Path(log).read_text():
    sys.exit(f"FAIL  utf8-wp/{target}: see {log} (unproved {failed}, missing {sorted(required - properties)})")
print(f"ok    utf8-wp/{target}: {len(goals)} obligations proved")
PY
