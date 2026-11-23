// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "third_party/dartino/two_space_heap.cc"
#undef protected
#undef private

using namespace toit;

extern ScavengeVisitor visitor;
extern OldSpace old_space;
extern Program image;
// Separate, non-overlapping regions at fixed offsets within one heap mapping.
static uword arena[10];
static uword* const source = arena;
static uword* const young = arena + 3;
static uword* const promoted = arena + 6;
static constexpr uword object_bytes = 3 * WORD_SIZE;
static HeapObject* original;
static unsigned sizes, young_allocations, promotion_attempts;
static bool promote, promotion_fails;

word HeapObject::size(Program* program) const {
  CXXV_ASSERT(this == original && program == &image && !has_forwarding_address(),
              "measure only the original before it has been forwarded");
  ++sizes;
  return object_bytes;
}

uword OldSpace::allocate(uword bytes) {
  CXXV_ASSERT(this == &old_space && promote && bytes == object_bytes && promotion_attempts == 0,
              "attempt promotion only once at the exact object size");
  ++promotion_attempts;
  return promotion_fails ? 0 : reinterpret_cast<uword>(promoted);
}

uword SemiSpace::allocate(uword bytes) {
  CXXV_ASSERT(this == visitor.to_space() && bytes == object_bytes && young_allocations == 0,
              "take one exact-size copy in the destination semispace");
  ++young_allocations;
  return reinterpret_cast<uword>(young);
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  visitor.program_ = &image;
  visitor.old_ = &old_space;
  visitor.from_start_ = reinterpret_cast<uword>(source);
  visitor.from_size_ = object_bytes;
  visitor.to_start_ = reinterpret_cast<uword>(young);
  visitor.to_size_ = object_bytes;
  original = HeapObject::from_address(visitor.from_start_);
  auto* young_object = HeapObject::from_address(visitor.to_start_);
  auto* old_object = HeapObject::from_address(reinterpret_cast<uword>(promoted));
  promote = nondet_bool();
  promotion_fails = nondet_bool();
  visitor.water_mark_ = visitor.from_start_ + (promote ? WORD_SIZE : 0);
  source[0] = reinterpret_cast<uword>(Smi::from(42));
  source[1] = nondet_ulong();
  source[2] = nondet_ulong();
  uword header = source[0], first = source[1], second = source[2];
  bool failed_before = nondet_bool();
  visitor.trigger_old_space_gc_ = failed_before;
  Object* stable = nondet_bool() ? static_cast<Object*>(Smi::from(7))
                                 : HeapObject::from_address(reinterpret_cast<uword>(arena + 9));
  Object* roots[] = {original, stable, original};
  uint8 record = nondet_uchar(), initial_record = record;
  visitor.set_record_new_space_pointers(&record);
  visitor.ScavengeVisitor::do_roots(roots, ARRAY_SIZE(roots));
  bool copied_young = !promote || promotion_fails;
  auto* destination = copied_young ? young_object : old_object;
  uword* copy = copied_young ? young : promoted;
  CXXV_ASSERT(roots[0] == destination && roots[2] == destination && roots[1] == stable &&
              original->forwarding_address() == destination, "preserve aliases and unrelated slots");
  CXXV_ASSERT(copy[0] == header && copy[1] == first && copy[2] == second &&
              source[1] == first && source[2] == second, "copy the original bytes before overwriting only its header");
  CXXV_ASSERT(promotion_attempts == static_cast<unsigned>(promote) &&
              young_allocations == static_cast<unsigned>(copied_young) && sizes == promotion_attempts + young_allocations,
              "each alias reuses the first successful copy");
  CXXV_ASSERT(visitor.trigger_old_space_gc() == (failed_before || (promote && promotion_fails)),
              "request old-space collection on failed promotion");
  CXXV_ASSERT(record == (copied_young ? GcMetadata::NEW_SPACE_POINTERS : initial_record),
              "record young survivors without clearing existing card state");
  record = 0;
  visitor.ScavengeVisitor::do_roots(&roots[1], 1);  // An outside root needs no mark.
  CXXV_ASSERT(record == 0, "visiting a stable outside root leaves the card alone");
  Object* later_alias = original;
  visitor.ScavengeVisitor::do_roots(&later_alias, 1);
  CXXV_ASSERT(later_alias == destination && record == (copied_young ? GcMetadata::NEW_SPACE_POINTERS : 0),
              "an already forwarded alias dirties its own card exactly for a young destination");
}
