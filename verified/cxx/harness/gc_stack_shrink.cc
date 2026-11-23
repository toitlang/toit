// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "objects_inline.h"
#include "interpreter_v2.h"
#include "third_party/dartino/object_memory.h"
using namespace toit;

extern Program image;

static uword* slots;
static word old_top, new_top, old_length, new_length, probe;
static bool moved, filled;

// Observe one arbitrary word. memmove reads this word from the pre-copy
// source, including when the ranges overlap.
static void* observe_move(void* dst, const void* src, size_t bytes) {
  CXXV_ASSERT(!moved && !filled && new_top < old_top, "one required move");
  CXXV_ASSERT(dst == slots + new_top && src == slots + old_top &&
              bytes == (old_length - old_top) * sizeof(uword), "move exactly the live slice");
  if (probe >= new_top && probe < new_length) slots[probe] = slots[old_top + (probe - new_top)];
  moved = true;
  return dst;
}

// The gc-stack-fill VeriFast proof supplies this pointwise store contract.
namespace toit {
template<> inline void Utils::fill_words<Object*>(Object** dst, uword count, Object* value) {
  CXXV_ASSERT(moved && !filled && dst == reinterpret_cast<Object**>(slots + new_length) &&
              count == static_cast<uword>(old_length - new_length), "fill exactly the released tail after moving");
  uword native_header;
  HeapObject::from_address(reinterpret_cast<uword>(&native_header))->_set_header(
      Smi::from(SINGLE_FREE_WORD_CLASS_ID), SINGLE_FREE_WORD_TAG);
  CXXV_ASSERT(reinterpret_cast<uword>(value) == native_header, "released words are one-word free objects");
  if (probe >= new_length) slots[probe] = native_header;
  filled = true;
}
}
#define memmove observe_move
#include "objects.cc"
#undef memmove
#undef protected
#undef private

class ShrinkPolicy : public RootCallback {
 public:
  bool enabled;
  bool shrink_stacks() const override { return enabled; }
  void do_roots(Object**, word) override { CXXV_ASSERT(false, "shrinking does not visit roots"); }
};

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  old_length = nondet_word();
  old_top = nondet_word();
  probe = nondet_word();
  CXXV_ASSUME(old_length > 0 && old_length < Stack::V2_MAX_LENGTH);
  CXXV_ASSUME(old_top >= 0 && old_top <= old_length && probe >= 0 && probe < old_length);
  uword records = nondet_ulong(), bci = nondet_ulong();
  word record_top = records & 0xffff;
  CXXV_ASSUME(record_top <= old_top);
  int height = nondet_int();
  bool aggressive = nondet_bool();
  ShrinkPolicy policy;
  policy.enabled = nondet_bool();
  int64 reserve = static_cast<int64>(height) * 2 + record_top + RESERVED_STACK_FOR_CALLS +
                  Stack::V2_FRAME_WORDS + Stack::V2_STACK_RESERVE;
  int64 excess = old_top - reserve;
  bool shrink = height >= 0 && excess > 0 &&
                (aggressive || (policy.enabled && old_top > old_length / 2 && excess >= 8));
  new_top = shrink ? static_cast<word>(reserve) : old_top;
  new_length = new_top + (old_length - old_top);
  auto* raw = static_cast<uword*>(malloc(Stack::HEADER_SIZE + (old_length + 1) * WORD_SIZE));
  CXXV_ASSUME(raw != nullptr && reinterpret_cast<uword>(raw) % WORD_SIZE == 0);
  auto* stack = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(raw)));
  slots = raw + Stack::HEADER_SIZE / WORD_SIZE;
  uint16 stack_class = Program::compute_class_bits(STACK_TAG, 0);
  image.class_bits = List<uint16>(&stack_class, 1);
  stack->_set_header(Smi::from(0), STACK_TAG);
  uword following_header = nondet_ulong();
  slots[old_length] = following_header;
  auto* object = static_cast<HeapObject*>(stack);
  uword base = reinterpret_cast<uword>(raw);
  stack->_set_length(old_length);
  CXXV_ASSERT(base + object->size(&image) == reinterpret_cast<uword>(slots + old_length),
              "the original stack ends at the following heap boundary");
  stack->_set_top(old_top);
  stack->_set_try_top(records);
  stack->v2_set_bci(bci);
  slots[probe] = nondet_ulong();
  bool live = probe >= new_top && probe < new_length;
  word source = live ? old_top + (probe - new_top) : probe;
  slots[source] = nondet_ulong();
  uword expected = slots[source];
  if (probe >= new_length) expected = reinterpret_cast<uword>(FreeListRegion::single_free_word_header());
  word result = stack->shrink_v2_for_gc(old_top, height, aggressive, &policy);
  CXXV_ASSERT(result == new_top && stack->top() == new_top && stack->length() == new_length,
              "new stack limits preserve the number of live slots");
  CXXV_ASSERT(stack->_stack_limit_addr() == reinterpret_cast<Object**>(slots),
              "scanner receives the base of the slot array");
  CXXV_ASSERT(moved == shrink && filled == shrink, "move and fill precisely when shrinking");
  CXXV_ASSERT(stack->v2_records_word() == records && stack->v2_bci_word() == bci, "preserve execution metadata");
  CXXV_ASSERT(record_top <= new_top && slots[probe] == expected,
              "preserve records and gap, retain each live value, and fill the entire tail");
  uword following = reinterpret_cast<uword>(slots + old_length);
  uword retained_end = reinterpret_cast<uword>(slots + new_length);
  CXXV_ASSERT(!has_sentinel_at(base) && base + object->size(&image) == retained_end && retained_end <= following,
              "after visitation the native walker steps to the first released word or the original successor");
  if (probe >= new_length) {
    uword here = reinterpret_cast<uword>(slots + probe);
    auto* filler = HeapObject::from_address(here);
    CXXV_ASSERT(!has_sentinel_at(here) && filler->class_tag() == SINGLE_FREE_WORD_TAG &&
                filler->size(&image) == WORD_SIZE && here + WORD_SIZE <= following,
                "each released word is a nonsentinel boundary whose native size advances one word");
    filler->roots_do(&image, &policy);
  }
  CXXV_ASSERT(slots[old_length] == following_header && has_sentinel_at(following) == (following_header == 0),
              "the original successor header and its sentinel status survive shrinking");
}
