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

# Installs the verification tools of the C++ verification pilot
# (verified/CXX-VERIFICATION-PILOT.md) without root, from release binaries,
# under $CXXV_HOME (default
# /home/flo/work/opentoit-sandbox-artifacts/cxx-verification).
#
# Usage: verified/cxx/install-tools.sh [esbmc] [cbmc] [kani] [crux] [framac] [cn]
#   (no argument: esbmc and cbmc)
# Afterwards: `source verified/cxx/env.sh`.

set -euo pipefail

CXXV_HOME=${CXXV_HOME:-/home/flo/work/opentoit-sandbox-artifacts/cxx-verification}
DL=$CXXV_HOME/downloads
TOOLS=$CXXV_HOME/tools
mkdir -p "$DL" "$TOOLS"

GH=https://github.com
ESBMC_VERSION=v8.6
CBMC_VERSION=6.11.0
KANI_VERSION=0.68.0
CRUX_VERSION=0.12
OPAM_VERSION=2.6.1
LLVM21_VERSION=21.1.8
OCAML_VERSION=5.3.0

install_esbmc() {
  local dir=$DL/esbmc-$ESBMC_VERSION
  mkdir -p "$dir"
  [ -f "$dir/esbmc-linux.zip" ] || \
    curl -sSL -o "$dir/esbmc-linux.zip" "$GH/esbmc/esbmc/releases/download/$ESBMC_VERSION/esbmc-linux.zip"
  rm -rf "$TOOLS/esbmc"
  mkdir -p "$TOOLS/esbmc"
  unzip -q "$dir/esbmc-linux.zip" -d "$TOOLS/esbmc"
  find "$TOOLS/esbmc" -name esbmc -type f -exec chmod +x {} \;
}

install_cbmc() {
  # The Ubuntu package is a plain ar archive; unpack it instead of dpkg -i.
  local dir=$DL/cbmc-$CBMC_VERSION
  mkdir -p "$dir"
  [ -f "$dir/cbmc.deb" ] || \
    curl -sSL -o "$dir/cbmc.deb" "$GH/diffblue/cbmc/releases/download/cbmc-$CBMC_VERSION/ubuntu-24.04-cbmc-$CBMC_VERSION-Linux.deb"
  rm -rf "$TOOLS/cbmc" "$dir/unpack"
  mkdir -p "$TOOLS/cbmc" "$dir/unpack"
  (cd "$dir/unpack" && ar x "$dir/cbmc.deb")
  tar -xf "$dir"/unpack/data.tar.* -C "$TOOLS/cbmc"
}

install_kani() {
  # Kani is CBMC for Rust: cargo installs the driver; `cargo kani setup`
  # unpacks the release bundle (kani-compiler, CBMC) into KANI_HOME and
  # installs the pinned nightly toolchain. RUSTUP_HOME and CARGO_HOME point
  # under $TOOLS so the user's own toolchains are not touched.
  local dir=$DL/kani-$KANI_VERSION
  mkdir -p "$dir"
  local bundle=kani-$KANI_VERSION-x86_64-unknown-linux-gnu.tar.gz
  [ -f "$dir/$bundle" ] || \
    curl -sSL -o "$dir/$bundle" "$GH/model-checking/kani/releases/download/kani-$KANI_VERSION/$bundle"
  export CARGO_HOME=$TOOLS/kani/cargo
  export RUSTUP_HOME=$TOOLS/kani/rustup
  export KANI_HOME=$TOOLS/kani/home
  mkdir -p "$CARGO_HOME" "$RUSTUP_HOME" "$KANI_HOME"
  rustup toolchain install stable --profile minimal
  rustup default stable
  cargo install --locked --root "$TOOLS/kani" kani-verifier --version "$KANI_VERSION"
  "$TOOLS/kani/bin/cargo-kani" setup --use-local-bundle "$dir/$bundle"
}

install_crux() {
  # crux-llvm (Galois): symbolic execution of LLVM bitcode.
  local dir=$DL/crux-$CRUX_VERSION
  mkdir -p "$dir"
  local tarball=crux-llvm-$CRUX_VERSION-ubuntu-24.04-X64.tar.gz
  [ -f "$dir/$tarball" ] || \
    curl -sSL -o "$dir/$tarball" "$GH/GaloisInc/crucible/releases/download/crux-v$CRUX_VERSION/$tarball"
  rm -rf "$TOOLS/crux"
  mkdir -p "$TOOLS/crux"
  tar -xzf "$dir/$tarball" -C "$TOOLS/crux" --strip-components=1
}

install_llvm21() {
  # crux-llvm 0.12 reads LLVM bitcode up to LLVM 21; the host clang (23)
  # writes bitcode it cannot parse. The official LLVM release binaries.
  local dir=$DL/llvm-$LLVM21_VERSION
  mkdir -p "$dir"
  local tarball=LLVM-$LLVM21_VERSION-Linux-X64.tar.xz
  [ -f "$dir/$tarball" ] || \
    curl -sSL -o "$dir/$tarball" "$GH/llvm/llvm-project/releases/download/llvmorg-$LLVM21_VERSION/$tarball"
  rm -rf "$TOOLS/llvm21"
  mkdir -p "$TOOLS/llvm21"
  tar -xJf "$dir/$tarball" -C "$TOOLS/llvm21" --strip-components=1
}

install_opam_tools() {
  # Frama-C (WP, with Alt-Ergo and Z3) and CN (Cerberus) are OCaml programs
  # distributed through opam: the static opam binary, an opam root under
  # $TOOLS/opam, one switch, built from source (a long build).
  local dir=$DL/opam-$OPAM_VERSION
  mkdir -p "$dir" "$TOOLS/opam/bin"
  [ -f "$dir/opam" ] || \
    curl -sSL -o "$dir/opam" "$GH/ocaml/opam/releases/download/$OPAM_VERSION/opam-$OPAM_VERSION-x86_64-linux"
  install -m 755 "$dir/opam" "$TOOLS/opam/bin/opam"
  export OPAMROOT=$TOOLS/opam/root
  export OPAMYES=1
  local opam=$TOOLS/opam/bin/opam
  [ -d "$OPAMROOT" ] || "$opam" init --bare --disable-sandboxing --no-setup
  "$opam" switch list | grep -q cxxv || "$opam" switch create cxxv "$OCAML_VERSION"
  "$opam" install --switch=cxxv -y "$@"
}

install_framac() {
  install_opam_tools frama-c alt-ergo z3
}

install_cn() {
  # CN is not released on opam: pin the Cerberus repository.
  install_opam_tools z3
  "$TOOLS/opam/bin/opam" pin --switch=cxxv -y add cn "$GH/rems-project/cerberus.git"
}

if [ $# -eq 0 ]; then set -- esbmc cbmc; fi
for tool in "$@"; do
  "install_$tool"
done
du -sh "$TOOLS"/* 2>/dev/null
