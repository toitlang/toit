#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Runs VeriFast's C++ front end (vf-cxx-ast-exporter, Clang based) alone on
# a file, to see the Clang diagnostics VeriFast itself does not print (it
# only reports "unable to deserialize the received message").
#
# Usage: cxx-ast.sh FILE [CLANG-ARGS...]

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
file="$1"; shift
out="$ACXX_WORK/logs/$(basename "$file").ast"
"$VERIFAST_DIR/bin/vf-cxx-ast-exporter" "$file" -- -I "$VERIFAST_DIR/bin" -nostdinc "$@" > "$out" 2> "$out.err"
status=$?
echo "exit $status; AST $(wc -c < "$out") bytes; diagnostics: $out.err"
grep -E "error|warning" "$out.err" | head -40
exit $status
