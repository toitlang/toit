#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Renders the sidecars (*.render) with verified/tools/cxx_render.toit: the C
# renderings of the C++ functions they name, from the current sources, with
# their annotations woven in.
#
# Usage: render.sh [--check] [SIDECAR...]
#   Without sidecars, all of them (the model first: every target shares its
#   signature table). --check: fail if a generated file is not what the
#   sources and sidecars give (drift), instead of rewriting it.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
acxx_lock

ARGS=()
if [ "${1:-}" = --check ]; then
  ARGS+=(--check)
  shift
fi
if [ $# -eq 0 ]; then
  cd "$ANNOTATED_DIR"
  # model/objects.render first, then the model's other sidecars (they
  # include objects.gen.h), then the rest.
  set -- model/objects.render $(ls model/*.render | grep -v '^model/objects\.render$' | sort) \
    $(ls */*.render | grep -v '^model/' | sort)
fi
TOIT_BIN="${TOIT:-$REPO_ROOT/build/host/sdk/bin/toit}"
[ -x "$TOIT_BIN" ] || TOIT_BIN="$(command -v toit)"
SCRATCH="${RENDER_SCRATCH:-$ACXX_WORK/scratch}"
mkdir -p "$SCRATCH" "$GEN32"
cd "$ANNOTATED_DIR"
# The 32-bit renderings (not committed: run.sh verifies them with
# -target ILP32) go to a mirror of this directory, with the hand-written
# headers and lemma files next to them.
for f in $(ls */*.h */*.gh 2>/dev/null | grep -v '\.gen\.'); do
  mkdir -p "$GEN32/$(dirname "$f")"
  cp "$f" "$GEN32/$f"
done
./prefetch-ast.sh "$REPO_ROOT" "$SCRATCH" "$@" || exit 1
exec "$TOIT_BIN" run "$REPO_ROOT/verified/tools/cxx_render.toit" -- --ast-ready \
  --repo "$REPO_ROOT" --scratch "$SCRATCH" --target "i686-linux-gnu=$GEN32" "${ARGS[@]}" "$@"
