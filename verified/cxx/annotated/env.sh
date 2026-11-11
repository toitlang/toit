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
# The flags the VM's C++ is compiled with that matter for its meaning (the
# language standard and the defines of src/CMakeLists.txt, the include
# paths; the version strings utils.cc gets), for the source tree $1: Clang's
# AST (clang-ast.sh) and the constant checks (constants-check.sh) see the
# code as the build does. Sets the array VM_CXX_FLAGS.
vm_cxx_flags() {
  local root="$1"
  VM_CXX_FLAGS=(-std=gnu++11 -DTOIT_DEPLOY -DTOIT_VERIFIED_CORE
    "-I$root/src" "-I$root/include" "-I$root/third_party/dragonbox/include"
    "-I$root/third_party/esp-idf/components/mbedtls/mbedtls/include"
    "-DMBEDTLS_CONFIG_FILE=\"$root/mbedtls/include/toit_config.h\""
    -DTOIT_MODEL='"render"' -DVM_GIT_INFO='"render"' -DVM_GIT_VERSION='"render"')
}

# The 32-bit renderings (render.sh), verified with -target ILP32.
GEN32="${GEN32:-$ACXX_HOME/gen/ilp32}"
export ACXX_HOME VERIFAST_DIR VERIFAST CXXV_HOME ANNOTATED_DIR REPO_ROOT GEN32
