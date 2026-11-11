# Copyright (C) 2026 Toit contributors.
#
# Paths of the annotation-based verifiers of the second C++ pilot
# (verified/CXX-ANNOTATED-PILOT.md). Source this file.
#
# ACXX_HOME holds the tools and logs (not in the repository): see
# install-tools.sh for what is installed there.

ACXX_HOME="${ACXX_HOME:-/home/flo/work/opentoit-sandbox-artifacts/annotated-cxx}"
VERIFAST_VERSION="${VERIFAST_VERSION:-26.10}"
VERIFAST_DIR="$ACXX_HOME/tools/verifast-$VERIFAST_VERSION"
VERIFAST="$VERIFAST_DIR/bin/verifast"
# Frama-C of the first pilot (opam switch under its artifacts directory).
CXXV_HOME="${CXXV_HOME:-/home/flo/work/opentoit-sandbox-artifacts/cxx-verification}"
ANNOTATED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$ANNOTATED_DIR/../../.." && pwd)"
export ACXX_HOME VERIFAST_DIR VERIFAST CXXV_HOME ANNOTATED_DIR REPO_ROOT
