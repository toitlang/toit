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

# The tools under ACXX_HOME are shared; what a run writes (Clang's AST
# dumps, the 32-bit renderings, the logs, the mutants' copies) is per
# checkout: worktrees and the main checkout run the matrix at the same
# time, and a shared AST dump written by two runs at once reads as two
# definitions of every function in it.
ACXX_WORK="${ACXX_WORK:-$ACXX_HOME/work/$(basename "$REPO_ROOT")-$(printf '%s' "$REPO_ROOT" | cksum | cut -d' ' -f1)}"
mkdir -p "$ACXX_WORK/logs"
# The 32-bit renderings (render.sh), verified with -target ILP32.
GEN32="${GEN32:-$ACXX_WORK/gen/ilp32}"
export ACXX_HOME ACXX_WORK VERIFAST_DIR VERIFAST CXXV_HOME ANNOTATED_DIR REPO_ROOT GEN32

# Takes the checkout's lock (one run of the matrix or of render.sh at a
# time per checkout; nested calls inherit it through ACXX_LOCKED). With an
# argument, a separate lock of that name (run.sh --slow: `slow`).
acxx_lock() {
  [ -n "${ACXX_LOCKED:-}" ] && return
  local lock="$ACXX_WORK/lock${1:+-$1}"
  exec 9> "$lock"
  if ! flock -n 9; then
    echo "waiting for another run in this checkout ($lock)" >&2
    flock 9
  fi
  export ACXX_LOCKED=1
}

# The Toit executable that runs the tools of verified/tools (TOIT, else the
# checkout's host SDK, else the one on PATH): ACXX_TOIT, and acxx_toit ARGS...
ACXX_TOIT="${TOIT:-$REPO_ROOT/build/host/sdk/bin/toit}"
[ -x "$ACXX_TOIT" ] || ACXX_TOIT="$(command -v toit || echo "$ACXX_TOIT")"
acxx_toit() {
  "$ACXX_TOIT" "$@"
}

# wp_report NAME REPORT LOG PROPERTY...: passes when every goal of the
# Frama-C/WP JSON report REPORT is valid, every PROPERTY is among its
# goals and WP's output LOG has no memory model hypotheses (WP's exit
# status alone allows unproved goals); see verified/tools/wp_report.toit.
wp_report() {
  acxx_toit run "$REPO_ROOT/verified/tools/wp_report.toit" -- "$@"
}
