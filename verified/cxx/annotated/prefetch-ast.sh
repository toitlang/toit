#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Runs, in parallel, every Clang AST dump the sidecars need (one per
# translation unit, target and filter, as cxx_render.toit names them), so
# that cxx_render.toit --ast-ready only reads them. Each dump is made anew.
#
# Usage: prefetch-ast.sh REPO SCRATCH SIDECAR...

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
repo="$1"; scratch="$2"; shift 2
mkdir -p "$scratch"
declare -A seen=()
pids=()
for sidecar in "$@"; do
  while read -r _ path qname rest; do
    tu="$path"
    for opt in $rest; do
      case "$opt" in tu=*) tu="${opt#tu=}" ;; esac
    done
    if [[ "$qname" == toit::* ]]; then filter="toit::"; else filter="$qname"; fi
    for target in host i686-linux-gnu; do
      tag="${filter//::/}"
      out="$scratch/ast-$(basename "$tu")-$target-${tag//\//_}.json"
      [ -n "${seen[$out]:-}" ] && continue
      seen[$out]=1
      targs=()
      [ "$target" != host ] && targs=(--target "$target")
      bash "$ANNOTATED_DIR/clang-ast.sh" "${targs[@]}" --repo "$repo" "$tu" "$filter" "$out" &
      pids+=($!)
    done
  done < <(grep -E '^@render ' "$sidecar")
done
status=0
for p in "${pids[@]}"; do wait "$p" || status=1; done
exit $status
