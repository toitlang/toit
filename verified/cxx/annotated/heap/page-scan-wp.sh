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
work=$(mktemp -d "$ACXX_WORK/page-scan-wp.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"
log="$ACXX_WORK/logs/page-scan-wp-$1.log"
report="$ACXX_WORK/logs/page-scan-wp-$1.json"
# A step limit, not a time limit, decides each goal: the slowest goals
# (record_overflow_sequence) take 6-8 s alone and timed out at 15 s with the
# matrix running beside them. Alone they need between 100000 and 150000
# Alt-Ergo steps; the wall-clock timeout only stops a hung prover.
frama-c -machdep "$machdep" -wp -wp-rte -wp-prover alt-ergo -wp-steps 1000000 -wp-timeout 600 \
  -wp-cache none -wp-report-json goals.json "$ANNOTATED_DIR/heap/page_scan.c" > "$log" 2>&1
cp goals.json "$report"
required=(
  first_free_page_ensures first_free_page_ensures_2 first_free_page_ensures_3
  first_free_page_loop_variant first_free_page_terminates first_free_page_assigns
  first_free_page_assert_rte_mem_access free_page_offset_requires
  page_run_mask_ensures page_run_mask_assert_rte_shift_2
  claim_page_run_ensures claim_page_run_assigns claim_page_run_assert_rte_mem_access_2
  release_page_run_ensures release_page_run_assigns release_page_run_assert_rte_mem_access_2
  sweep_empty_cards_ensures sweep_empty_cards_ensures_{2..6}
  sweep_empty_cards_assigns sweep_empty_cards_loop_variant
  sweep_empty_cards_assert_rte_mem_access sweep_empty_cards_assert_rte_mem_access_2
  fill_unmarked_words_ensures fill_unmarked_words_ensures_2 fill_unmarked_words_assigns
  fill_unmarked_words_loop_variant fill_unmarked_words_assert_rte_mem_access
  fill_unmarked_words_assert_rte_shift
  sweep_card_step_ensures sweep_card_step_ensures_{2..10}
  sweep_card_step_assigns sweep_card_step_requires_2
  sweep_marked_visits_loop_variant sweep_marked_visits_ensures sweep_marked_visits_terminates
  record_overflow_start_ensures record_overflow_start_ensures_{2..6}
  record_overflow_sequence_ensures record_overflow_sequence_ensures_{2..4}
  record_overflow_sequence_loop_variant record_overflow_sequence_terminates
)
wp_report "page-scan-wp-$1" "$report" "$log" "${required[@]}"
