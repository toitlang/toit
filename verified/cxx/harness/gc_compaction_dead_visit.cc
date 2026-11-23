// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "third_party/dartino/object_memory_mark_sweep.cc"
#undef protected
#undef private

using namespace toit;

extern CompactingVisitor visitor;
GcMetadata GcMetadata::singleton_;

// The release-build scan must stop on the bitmap without reading object data.
word HeapObject::size(Program*) const {
  CXXV_ASSERT(false, "the dead-object scan does not inspect a header");
  return 0;
}
void HeapObject::roots_do(Program*, RootCallback*) {
  CXXV_ASSERT(false, "the dead-object scan does not visit roots");
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS && GcMetadata::CARD_SIZE == 32 * WORD_SIZE, "card geometry");
  constexpr unsigned count = 4;
  uword base = nondet_ulong();
  CXXV_ASSUME(base % GcMetadata::CARD_SIZE == 0 && base <= UINTPTR_MAX - count * GcMetadata::CARD_SIZE);
  unsigned start = nondet_uint() % 32, next = nondet_uint() % (32 * count);
  CXXV_ASSUME(start < next);
  // Bits before start and after next may describe any other objects. The
  // final word is the sentinel installed by CompactingVisitor::chunk_start.
  uint32 marks[count];
  for (unsigned i = 0; i < count; ++i) {
    uint32 free_bits = i == 0 ? (uint32(1) << start) - 1 : 0;
    uint32 required = 0;
    if (i == next / 32) {
      required = uint32(1) << (next % 32);
      free_bits |= ~(required - 1);
    }
    if (i > next / 32) free_bits = UINT32_MAX;
    marks[i] = (nondet_uint() & free_bits) | required;
  }
  marks[count - 1] |= uint32(1) << 31;
  GcMetadata::singleton_.mark_bits_bias_ = reinterpret_cast<uword>(marks) - (base >> GcMetadata::MARK_BITS_SHIFT);

  uword used = nondet_ulong(), dest = nondet_ulong(), limit = nondet_ulong();
  visitor.used_ = used;
  visitor.dest_.address = dest;
  visitor.dest_.limit = limit;
  uword distance = visitor.CompactingVisitor::visit(HeapObject::from_address(base + start * WORD_SIZE));
  CXXV_ASSERT(distance == (next - start) * WORD_SIZE, "skip exactly to the first following live word or sentinel");
  CXXV_ASSERT(visitor.used_ == used && visitor.dest_.address == dest && visitor.dest_.limit == limit,
              "skipping garbage preserves destination and live-byte accounting");
}
