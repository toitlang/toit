#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

# Installs the annotation-based verifiers of the second C++ pilot
# (verified/CXX-ANNOTATED-PILOT.md) without root, under $ACXX_HOME/tools.
#
# Usage: install-tools.sh verifast|llvm22|frama-clang|cn|verifast-rust ...
#
#   verifast     VeriFast release tarball (GitHub, 26.10).
#   llvm22       LLVM 22.1.8 release tarball (for frama-clang 0.0.20, which
#                needs libclang 22; the host has 23).
#   frama-clang  `opam install frama-clang` into the opam switch of the first
#                pilot ($CXXV_HOME/tools/opam/root, switch cxxv, Frama-C 33)
#                with LLVM 22's llvm-config first on the PATH.
#   cn           CN from github.com/rems-project/cn (its README: opam install
#                ./cn.opam) in an own opam root with OCaml 5.2.0, using the
#                static opam binary of the first pilot.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
DL="$ACXX_HOME/downloads"
TOOLS="$ACXX_HOME/tools"
OPAM="$CXXV_HOME/tools/opam/bin/opam"
mkdir -p "$DL" "$TOOLS"

install_verifast() {
  local v=26.10
  mkdir -p "$DL/vf"
  [ -f "$DL/vf/verifast-$v-linux.tar.gz" ] ||
    curl -sSL -o "$DL/vf/verifast-$v-linux.tar.gz" \
      "https://github.com/verifast/verifast/releases/download/$v/verifast-$v-linux.tar.gz"
  tar -C "$TOOLS" -xzf "$DL/vf/verifast-$v-linux.tar.gz"
  "$TOOLS/verifast-$v/bin/verifast" | head -1
}

install_llvm22() {
  local v=22.1.8
  mkdir -p "$DL/llvm22"
  [ -f "$DL/llvm22/LLVM-$v-Linux-X64.tar.xz" ] ||
    curl -sSL -o "$DL/llvm22/LLVM-$v-Linux-X64.tar.xz" \
      "https://github.com/llvm/llvm-project/releases/download/llvmorg-$v/LLVM-$v-Linux-X64.tar.xz"
  mkdir -p "$TOOLS/llvm22"
  tar -C "$TOOLS/llvm22" --strip-components=1 -xJf "$DL/llvm22/LLVM-$v-Linux-X64.tar.xz"
  # The release's CMake exports link libLLVMSupport against a static zstd,
  # which the host (Arch) does not ship: use the shared one.
  sed -i 's/zstd::libzstd_static/zstd::libzstd_shared/' "$TOOLS/llvm22/lib/cmake/llvm/LLVMExports.cmake"
  "$TOOLS/llvm22/bin/llvm-config" --version
}

install_frama_clang() {
  export OPAMROOT="$CXXV_HOME/tools/opam/root"
  # History: `opam install frama-clang` (0.0.20 from opam-repository) wants
  # conf-libclang 22; with the LLVM 22 release tarball (llvm22 above, after
  # a zstd fix in its CMake exports) it builds, but framaCIRGen's CMake asks
  # for the shared libLLVM (`llvm_config(... USE_SHARED ...)`), the release
  # has only static libraries, so the linker took the host's libLLVM.so.23
  # and framaCIRGen aborted at start ("no handler registered for module
  # format 'raw'"). The 0.0.20 source tarball's own opam file accepts
  # libclang 19-21, and the host has a consistent shared LLVM 21
  # (/usr/bin/llvm-config-21, /usr/lib/llvm21): pin the source and let opam
  # pick conf-libclang 21.
  local src="$DL/frama-clang/frama-clang-0.0.20"
  if [ ! -d "$src" ]; then
    mkdir -p "$DL/frama-clang"
    curl -sSL -o "$DL/frama-clang/fc.tar.bz2" \
      https://git.frama-c.com/pub/frama-clang/-/archive/0.0.20/frama-clang-0.0.20.tar.bz2
    tar -C "$DL/frama-clang" -xjf "$DL/frama-clang/fc.tar.bz2"
  fi
  sed -i 's/llvm_config(framaCIRGen Option Support)/llvm_config(framaCIRGen USE_SHARED Option Support)/' \
    "$src/framaCIRGen_src/CMakeLists.txt"
  export PATH="/usr/lib/llvm21/bin:$PATH"
  unset OPAM_LLVM_CONFIG
  "$OPAM" pin add --switch cxxv --yes --kind path frama-clang "$src"
}

install_cn() {
  export OPAMROOT="$TOOLS/opam-cn"
  if [ ! -d "$OPAMROOT" ]; then
    "$OPAM" init --yes --bare --disable-sandboxing --no-setup
    "$OPAM" switch create cn 5.2.0 --yes
  fi
  if [ ! -d "$DL/cn-src" ]; then
    git clone --depth 1 https://github.com/rems-project/cn.git "$DL/cn-src"
  fi
  (cd "$DL/cn-src" && git log -1 --format='cn %H %cd')
  "$OPAM" install --switch cn --yes "$DL/cn-src/cn.opam" z3
}

install_verifast_rust() {
  # VeriFast's Rust front end runs `rustc +nightly-2026-09-25` (the
  # toolchain VeriFast 26.10 is built against) with rustc-dev.
  export RUSTUP_HOME="$TOOLS/rustup" CARGO_HOME="$TOOLS/cargo"
  rustup toolchain install nightly-2026-09-25 --profile minimal \
    --component rustc-dev,llvm-tools,rust-src
}

for what in "$@"; do
  case "$what" in
    verifast) install_verifast ;;
    llvm22) install_llvm22 ;;
    frama-clang) install_frama_clang ;;
    cn) install_cn ;;
    verifast-rust) install_verifast_rust ;;
    *) echo "unknown tool: $what" >&2; exit 2 ;;
  esac
done
