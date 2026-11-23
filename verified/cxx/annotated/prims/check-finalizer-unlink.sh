#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Compare the original FIFO specialization with the VeriFast loop compiled
# against the native layout. A relocation would require comparing its target
# as well as its bytes, so only accept self-contained function sections.
set -euo pipefail
export LC_ALL=C
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
case "$1" in
  LP64) bits=64; model="$ANNOTATED_DIR" ;;
  ILP32) bits=32; model="$GEN32" ;;
  *) exit 2 ;;
esac
work="$ACXX_WORK/finalizer-unlink-$1"
mkdir -p "$work"
vm_cxx_flags "$REPO_ROOT"
native="$REPO_ROOT/src/heap.cc"
section=.text._ZN4toit10ObjectHeap26unlink_callable_finalizersEPNS_8InstanceE

# The proof collapses the C++ base link and the derived node to one type.
# Use native links for traversal. Only the key read and virtual deletion
# need the conversion from a base subobject back to its owning node.
cat > "$work/model.cc" <<'CPP'
#include "heap.h"
namespace toit {
static inline void FinalizerNode_delete(FinalizerNodeFifo::Element* link) {
  delete static_cast<FinalizerNode*>(link);
}
void ObjectHeap::unlink_callable_finalizers(Instance* key) {
  using FinalizerNode = FinalizerNodeFifo::Element;
  ObjectHeap* self = this;
CPP
awk '
  /^void ObjectHeap_unlink_callable_finalizers\(ObjectHeap \*self, Instance \*key\)$/ { found++; signature=1; next }
  signature && /^\{$/ { signature=0; body=1; next }
  body {
    sub(/current->key_/, "static_cast<toit::FinalizerNode*>(current)->key_")
    print
    if ($0 == "}") { body=0; complete++ }
  }
  END { if (found != 1 || complete != 1) exit 1 }
' "$model/prims/finalizers.gen.c" >> "$work/model.cc"
echo '}' >> "$work/model.cc"

compile_body() {
  local file="$1" stem="$2"
  "${CLANGXX:-clang++}" "-m$bits" "${VM_CXX_FLAGS[@]}" -O1 -fno-rtti -fno-exceptions \
    -fno-strict-aliasing -ffunction-sections "${@:3}" -c "$file" -o "$work/$stem.o"
  local relocations
  relocations=$(objdump -r -j "$section" "$work/$stem.o")
  if [[ "$relocations" == *"RELOCATION RECORDS"* ]]; then
    echo "unsupported relocation in $stem: $relocations" >&2
    return 1
  fi
  objcopy -O binary --only-section="$section" "$work/$stem.o" "$work/$stem.bin"
  test -s "$work/$stem.bin"
}
compile_body "$native" native
compile_body "$work/model.cc" model -fno-access-control
cmp "$work/native.bin" "$work/model.bin"
echo "ok    finalizer-unlink-code/$1: $(wc -c < "$work/native.bin") identical relocation-free bytes"

if [[ ${2:-} == --mutant ]]; then
  # The production predicate must affect the compared function, including
  # calls inlined from the lambda and the generic list helper.
  sed '/^void ObjectHeap::unlink_callable_finalizers(/,/^}/s/if (node->key() != key)/if (node->key() == key)/' \
    "$native" > "$work/reversed.cc"
  compile_body "$work/reversed.cc" reversed
  if cmp -s "$work/reversed.bin" "$work/model.bin"; then
    echo "FAIL  finalizer-unlink-code/$1: reversed native predicate matched" >&2
    exit 1
  fi
  echo "ok    finalizer-unlink-code/$1: reversed native predicate rejected"
fi
