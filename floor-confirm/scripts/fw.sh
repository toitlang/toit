#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Builds a Toit firmware of the device/esp32-layout worktree for a target (never
# flashes) and copies the envelope, elf, map and sizes to bins/<target>-<name>.
# Usage: fw.sh TARGET NAME [SDKCONFIG-LINE...]
#   TARGET: esp32, esp32c6, esp32c3, esp32s2, esp32s3
#   SDKCONFIG lines are appended to the target's sdkconfig (e.g.
#   CONFIG_TOIT_VERIFIED_CORE=y CONFIG_TOIT_CXX_INTERPRETER=n).
# The version string is pinned (the host SDK is built with the same value,
# sdk.sh), so container install accepts snapshots after new commits.
set -euo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-ade4ccc2a6557dc80}
A=/home/flo/work/opentoit-sandbox-artifacts/floor-confirm
TARGET=$1
NAME=$2
shift 2
export TMPDIR=$WT/build/tmp
# install-speed: build from a copy of the worktree's sources taken now
# (build/fwsrc, rsync keeps the times of unchanged files), so that the
# worktree can be edited while a firmware builds. SNAP=0: in place.
if [ "${SNAP:-1}" = 1 ]; then
  SRC=$WT
  WT=$SRC/build/fwsrc
  mkdir -p "$WT/build"
  rsync -a --delete --exclude /build --exclude /.git "$SRC/" "$WT/"
  [ -e "$WT/build/host" ] || ln -s "$SRC/build/host" "$WT/build/host"
  echo "sources: $(git -C "$SRC" rev-parse --short HEAD) $(git -C "$SRC" status --porcelain --untracked-files=no | wc -l) modified"
  # memory-pressure: SRCREV=<rev> builds the tracked files as of that
  # revision (files that differ from it in the worktree are replaced by
  # their committed version, files it does not have are removed, untracked
  # files too), so a firmware of a commit builds while the worktree is
  # being edited.
  if [ -n "${SRCREV:-}" ]; then
    git -C "$SRC" diff --name-only "$SRCREV" | while read -r f; do
      if git -C "$SRC" cat-file -e "$SRCREV:$f" 2>/dev/null; then
        git -C "$SRC" show "$SRCREV:$f" > "$WT/$f"
      else
        rm -f "$WT/$f"
      fi
    done
    git -C "$SRC" ls-files --others --exclude-standard | while read -r f; do rm -f "$WT/$f"; done
    echo "sources: tracked files as of $(git -C "$SRC" rev-parse --short "$SRCREV")"
  fi
  # memory-pressure: PATCH=<file> applies a diagnostic patch to the build
  # copy (after SRCREV).
  if [ -n "${PATCH:-}" ]; then
    patch -p1 -d "$WT" < "$PATCH"
    echo "patched with $PATCH"
  fi
  # esp32-final: EPOCHBUMP=1 bumps the manual component of the verification
  # epoch in the build's copy only (a scratch firmware with another epoch;
  # never committed). The next rsync restores the file.
  if [ "${EPOCHBUMP:-0}" = 1 ]; then
    sed -i 's/^set(TOIT_VERIFICATION_EPOCH_MANUAL 1)$/set(TOIT_VERIFICATION_EPOCH_MANUAL 2)/' "$WT/verified/verification-epoch.cmake"
    grep -q '^set(TOIT_VERIFICATION_EPOCH_MANUAL 2)$' "$WT/verified/verification-epoch.cmake"
    echo "verification epoch: manual component bumped in the build copy"
  fi
  # measure-3: KCONFIG_FROM=<rev> builds with the toit component's Kconfig
  # of that revision (e.g. e2cc27d1^, before TOIT_SILENT_IDF_CHECKS).
  if [ -n "${KCONFIG_FROM:-}" ]; then
    git -C "$SRC" show "$KCONFIG_FROM:toolchains/idf/components/toit/Kconfig" > "$WT/toolchains/idf/components/toit/Kconfig"
    echo "Kconfig from $KCONFIG_FROM"
  fi
fi
cd "$WT"
mkdir -p "$TMPDIR"
export IDF_PATH=/home/flo/work/opentoit-sandbox/third_party/esp-idf
export IDF_TOOLS_PATH=$HOME/.espressif
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" > /dev/null 2>&1
export IDF_TARGET=$TARGET
export IDF_CCACHE_ENABLE=1
export IGNORE_SUBMODULE=1
export TOIT_GIT_VERSION=v2.0.1-pre.999+floorconfirm
export CARGO_BUILD_JOBS=8
B="$WT/build/$TARGET-$NAME"
mkdir -p "$B"
cp "toolchains/$TARGET/sdkconfig" "$B.sdkconfig"
for line in "$@"; do
  key=${line%%=*}
  sed -i "/^$key=/d;/^# $key is not set/d" "$B.sdkconfig"
  case "$line" in
    *=n) echo "# $key is not set" >> "$B.sdkconfig" ;;
    *) echo "$line" >> "$B.sdkconfig" ;;
  esac
done
# Layout perturbation (PAD=N bytes): a function of N bytes of dead code in
# an ordinary .text section, compiled first among src/resources (so in
# flash right after objects_runtime.cc and vm.cc), shifts the flash
# addresses of almost all VM code by N. A constructor (in .text.startup,
# which the linker places elsewhere) keeps it alive under --gc-sections by
# storing its address. The file exists only during the build.
# (Builds named -pN before 2026-11-24 05:00 used the constructor itself as
# the pad: it landed near the end of the VM's text and shifted little.)
PADFILE=$WT/src/resources/aaa_layout_pad.cc
rm -f "$PADFILE"
# esp32-layout: RPAD=N, a data-side perturbation: N bytes of rodata in
# src/vm.cc (referenced from VM::VM(), so --gc-sections keeps them). vm.cc's
# rodata lies about 56 KB into .flash.rodata, so the pad shifts the rest of
# the rodata and the program images appended to the DROM segment
# (tools/firmware.toit, extend-drom) by N, while the code stays put.
if [ -n "${RPAD:-}" ]; then
  if [ "${SNAP:-1}" = 1 ]; then
    trap 'cp "$SRC/src/vm.cc" "$WT/src/vm.cc"' EXIT
  else
    trap 'git -C "$WT" checkout -- src/vm.cc' EXIT
  fi
  grep -q '^VM::VM() {$' "$WT/src/vm.cc"
  awk -v pad="$RPAD" '
    /^VM::VM\(\) \{$/ {
      print "extern \"C\" { extern const unsigned char toit_layout_rodata_pad[" pad "]; }"
      print "extern \"C\" { __attribute__((used)) const unsigned char toit_layout_rodata_pad[" pad "] = { 1 }; }"
      print
      print "  // Data-side layout perturbation of esp32-layout/scripts/fw.sh (RPAD=" pad ")."
      print "  __asm__ volatile(\"\" : : \"r\"(toit_layout_rodata_pad));"
      next
    }
    { print }' "$WT/src/vm.cc" > "$TMPDIR/vm.cc.rpad"
  cp "$TMPDIR/vm.cc.rpad" "$WT/src/vm.cc"
fi
if [ -n "${PAD:-}" ] && [ "${PADMODE:-vm}" = vm ]; then
  # The method used for the measurements: PAD bytes of dead code jumped
  # over at the start of VM::VM() (src/vm.cc, the VM's second object in
  # flash, placed at the start of the flash text), so nearly all of the
  # VM's flash code moves by PAD. src/vm.cc is restored from git after the
  # build. A pad in a function of its own (called from VM::VM(), kept by a
  # constructor, in its own object or appended to objects_runtime.cc; the
  # other two modes below) lands in a tail group of small VM sections that
  # the linker puts after newlib (0x401d....) and shifts only that tail.
  # measure-3: with SNAP=1 (build/fwsrc, no .git) the copy's vm.cc is put
  # back from the worktree; the next rsync would restore it anyway.
  if [ "${SNAP:-1}" = 1 ]; then
    trap 'cp "$SRC/src/vm.cc" "$WT/src/vm.cc"' EXIT
  else
    trap 'git -C "$WT" checkout -- src/vm.cc' EXIT
  fi
  grep -q '^VM::VM() {$' "$WT/src/vm.cc"
  awk -v pad="$PAD" '
    /^VM::VM\(\) \{$/ {
      print
      print "  // Layout perturbation of split-option/scripts/fw.sh (PAD=" pad ")."
      print "  __asm__ volatile(\"j 1f\\n.skip " pad "\\n1:\\n\");"
      next
    }
    { print }' "$WT/src/vm.cc" > "$TMPDIR/vm.cc.pad"
  cp "$TMPDIR/vm.cc.pad" "$WT/src/vm.cc"
elif [ -n "${PAD:-}" ] && [ "${PADMODE}" = first ]; then
  # Appended to src/objects_runtime.cc, the first object of the VM's text
  # (restored from git afterwards).
  trap 'git -C "$WT" checkout -- src/objects_runtime.cc' EXIT
  cat >> "$WT/src/objects_runtime.cc" <<EOF

// Layout perturbation of split-option/scripts/fw.sh (PAD=$PAD).
extern "C" __attribute__((noinline, used)) void toit_layout_pad() {
  __asm__ volatile("j 1f\n.skip $PAD\n1:\n");
}
extern "C" { void (* volatile toit_layout_pad_ref)(); }
__attribute__((constructor)) static void toit_layout_pad_keep() {
  toit_layout_pad_ref = toit_layout_pad;
}
EOF
elif [ -n "${PAD:-}" ]; then
  trap 'rm -f "$PADFILE"' EXIT
  cat > "$PADFILE" <<EOF
// Copyright (C) 2026 Toit contributors.
// Layout perturbation of split-option/scripts/fw.sh (PAD=$PAD); not part of
// the repository.
extern "C" __attribute__((noinline, used, section(".text.0toit_layout_pad"))) void toit_layout_pad() {
  __asm__ volatile("j 1f\n.skip $PAD\n1:\n");
}
extern "C" { void (* volatile toit_layout_pad_ref)(); }
__attribute__((constructor)) static void toit_layout_pad_keep() {
  toit_layout_pad_ref = toit_layout_pad;
}
EOF
fi
start=$(date +%s)
python "$IDF_PATH/tools/idf.py" -C "toolchains/$TARGET" -B "$B" -DSDKCONFIG="$B.sdkconfig" reconfigure
ninja -C "$B" -j "${JOBS:-8}" all
end=$(date +%s)
echo "build $TARGET-$NAME: $((end - start)) s"
O="$A/bins/$TARGET-$NAME"
mkdir -p "$O"
cp "$B/toit.elf" "$B/toit.bin" "$B/toit.map" "$B/firmware.envelope" "$B/system.snapshot" "$B.sdkconfig" "$O/"
case $TARGET in
  esp32|esp32s2|esp32s3) SIZE=xtensa-$TARGET-elf-size ;;
  *) SIZE=riscv32-esp-elf-size ;;
esac
"$SIZE" -A "$B/toit.elf" > "$O/sections.txt"
grep -E "^\.(iram0\.text|iram0\.vectors|dram0\.data|dram0\.bss|flash\.text|flash\.rodata|flash\.appdesc) " "$O/sections.txt" || true
echo "toit.bin $(stat -c %s "$B/toit.bin")"
