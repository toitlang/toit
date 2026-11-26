// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#ifdef CXXV_SYMBOLIC_FIELDS
#include "objects_inline.h"
namespace toit {
static void apply_field_fill(Object**, uword, Object*);
template<> inline void Utils::fill_words<Object*>(Object**, uword, Object*);
}
#include "instance_heap.inc"
#else
#include "heap.cc"
#endif
#include "objects.cc"
#include "third_party/dartino/object_memory_copying.cc"
namespace toit {
#include "task_old_bump.inc"

// A pending GC request must stop allocation before either slow path.
uword OldSpace::allocate_from_free_list(uword) {
  CXXV_ASSERT(false, "task retry with pending GC must not search free lists");
  return 0;
}

uword OldSpace::allocate_in_new_chunk(uword) {
  CXXV_ASSERT(false, "task retry with pending GC must not request a chunk");
  return 0;
}
}  // namespace toit
#include "third_party/dartino/two_space_heap.cc"
#undef protected
#undef private

using namespace toit;

extern Process caller;
extern Program image;
GcMetadata GcMetadata::singleton_;
// The initial stack length of the program's format (Stack::initial_length).
static word expected_length;

#ifdef CXXV_SYMBOLIC_FIELDS
static Object** expected_fields;
static unsigned field_count, chosen_field;
static Object* expected_null;
static Object** expected_slots;
static unsigned payload_fills;

// The task field fill is observed separately below. This specialization
// applies the independently proved stack fill to its actual reservation.
namespace toit {
template<> inline void Utils::fill_words<Object*>(Object** base, uword count, Object* value) {
  ++payload_fills;
  CXXV_ASSERT(base == expected_slots && count == static_cast<uword>(expected_length) && value == nullptr,
              "initialize exactly the reserved format-2 stack slots");
}
}  // namespace toit

// Use the proved Utils::fill_words contract at the field checked after
// allocate_task has installed the stack and task id.
void toit::apply_field_fill(Object** first, uword count, Object* value) {
  CXXV_ASSERT(first == expected_fields && count == field_count && value == expected_null,
              "supply exactly the fresh task fields and the program's null");
  first[chosen_field] = value;
}
#endif

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
#ifdef CXXV_SYMBOLIC_FIELDS
  bool format2 = nondet_bool();
  int fields = nondet_int();
  CXXV_ASSUME(fields >= Task::ID_INDEX + 1 && fields <= Program::INSTANCE_SIZE_MASK - Instance::HEADER_SIZE / WORD_SIZE);
#else
  bool format2 = false;
  int fields = 2 + nondet_uint() % 5;
#endif
  unsigned witness = nondet_uint();
  CXXV_ASSUME(witness < static_cast<unsigned>(fields));
  const int task_words = Instance::HEADER_SIZE / WORD_SIZE + fields;
  uint16 classes[] = {STACK_TAG, static_cast<uint16>((task_words << HeapObject::CLASS_ID_OFFSET) | TASK_TAG)};
  image.class_bits = List<uint16>(classes, 2);
  uint8 bytecodes[] = {'T', 'B', 'C', static_cast<uint8>(format2 ? '3' : 'x')};
  image.bytecodes = List<uint8>(bytecodes, 4);
  image.set_stack_class_id(Smi::from(0));
  image.set_task_class_id(Smi::from(1));
  uword null_header = 0;
  auto* null_value = HeapObject::from_address(reinterpret_cast<uword>(&null_header));
  image.set_null_object(null_value);
  // Construct in place so the two-space heap points back to this same owner.
  ObjectHeap local_heap(&image, &caller, nullptr, nullptr, nullptr);
  auto* heap = &local_heap;
  CXXV_ASSERT(heap->two_space_heap_.process_heap_ == heap, "retry queries the owning object heap");
  auto* space = heap->two_space_heap_.new_space();
  expected_length = Stack::initial_length(&image);
  const word stack_words = Stack::allocation_size(expected_length) / WORD_SIZE;
  const word page_words = TOIT_PAGE_SIZE / WORD_SIZE;
  static uword storage[2 * page_words];
  uword start = reinterpret_cast<uword>(storage);
  word capacity = nondet_word();
  CXXV_ASSUME(capacity >= 1 && capacity <= page_words);
  space->top_ = start;
  space->limit_ = start + capacity * WORD_SIZE;
  write_sentinel_at(start);

  auto* old = heap->two_space_heap_.old_space();
  uword old_start = reinterpret_cast<uword>(storage + page_words);
  bool retry = false;
  word old_words = 0;
#ifdef CXXV_TASK_RETRY
  // The stack misses the young window. A failed old bump leaves a
  // pending GC request, so the allocator returns before seeking a chunk.
  CXXV_ASSUME(capacity <= stack_words);
  retry = nondet_bool();
  old_words = nondet_word();
  CXXV_ASSUME(old_words >= 0 && old_words <= page_words);
#endif
  heap->retrying_primitive_ = retry;
  old->top_ = old_start;
  old->limit_ = old_start + old_words * WORD_SIZE;
  old->set_used((old_words + 1) * WORD_SIZE);
  old->set_promotion_failed(true);
  uint64 previous_bytes = static_cast<uint64>(nondet_int64());
  heap->two_space_heap_.total_bytes_allocated_.store(previous_bytes);
  uint32 next = nondet_uint();
  caller.next_task_id_ = next;
  bool has_id = next <= (sizeof(word) == 4 ? (UINT32_C(1) << 30) - 1 : INT32_MAX);
  bool young_stack = has_id && capacity > stack_words;
  bool old_stack = has_id && !young_stack && retry && old_words >= stack_words;
  bool has_stack = young_stack || old_stack;
  word young_stack_words = young_stack ? stack_words : 0;
  bool success = has_stack && capacity - young_stack_words > task_words;
  auto* stack = static_cast<Stack*>(HeapObject::from_address(old_stack ? old_start : start));
  auto* task = static_cast<Task*>(HeapObject::from_address(start + young_stack_words * WORD_SIZE));
#ifdef CXXV_SYMBOLIC_FIELDS
  expected_slots = reinterpret_cast<Object**>(storage + (old_stack ? page_words : 0) + Stack::HEADER_SIZE / WORD_SIZE);
  expected_fields = reinterpret_cast<Object**>(storage + young_stack_words + Instance::HEADER_SIZE / WORD_SIZE);
  field_count = fields;
  chosen_field = witness;
  expected_null = null_value;
#endif
  const word pages_in_cards = TOIT_PAGE_SIZE / GcMetadata::CARD_SIZE;
  uint8 cards[2 * pages_in_cards + 1] = {};
  uword first_card = start >> GcMetadata::CARD_SIZE_LOG_2;
  GcMetadata::singleton_.remembered_set_bias_ = reinterpret_cast<uword>(cards) - first_card;
  uint8 old_start_byte = nondet_uchar();
  uint8 previous_start_byte = old_start_byte;
  GcMetadata::singleton_.starts_bias_ = reinterpret_cast<uword>(&old_start_byte) -
      (old_start >> GcMetadata::CARD_SIZE_LOG_2);

  auto* result = heap->allocate_task();
#ifdef CXXV_SYMBOLIC_FIELDS
  CXXV_ASSERT(payload_fills == unsigned(has_stack && format2),
              "initialize a format-2 reservation even if subsequent task allocation fails");
#endif
  CXXV_ASSERT(result == (success ? task : nullptr) && caller.next_task_id_ == next + static_cast<unsigned>(success),
              "consume exactly one task id after both reservations succeed");
  CXXV_ASSERT(space->top_ == start + (young_stack_words + (success ? task_words : 0)) * WORD_SIZE &&
              has_sentinel_at(space->top_), "preserve the end sentinel after every allocation outcome");
  CXXV_ASSERT(old->top_ == old_start + (old_stack ? stack_words * WORD_SIZE : 0) &&
              old_start_byte == (old_stack ? static_cast<uint8>(old_start) : previous_start_byte),
              "record the old stack's exact reservation and start byte even when task allocation later fails");
  CXXV_ASSERT(heap->two_space_heap_.total_bytes_allocated_.load() ==
              previous_bytes + static_cast<uint64>(old_stack ? stack_words * WORD_SIZE : 0),
              "charge the old stack exactly once independently of task publication");
  unsigned card = nondet_uint();
  CXXV_ASSUME(card < sizeof(cards));
  uword task_card = (reinterpret_cast<uword>(task) >> GcMetadata::CARD_SIZE_LOG_2) - first_card;
  bool dirty = (success && card == task_card) || (old_stack && card == pages_in_cards);
  CXXV_ASSERT(cards[card] == (dirty ? GcMetadata::NEW_SPACE_POINTERS : 0),
              "mark only the directly allocated old stack and the published task");
  if (has_stack) {
    CXXV_ASSERT(stack->has_class_tag(STACK_TAG) && stack->class_id() == image.stack_class_id() &&
                stack->length() == expected_length && stack->top() == stack->length() &&
                stack->try_top() == stack->length() && !stack->pending_stack_check_method().is_valid() &&
                !stack->is_guard_zone_touched(), "initialize an empty stack with intact guards");
  }
  if (success) {
    CXXV_ASSERT(task->has_class_tag(TASK_TAG) && task->class_id() == image.task_class_id() &&
                task->stack() == stack && task->id() == next, "link the allocated stack and the issued task id");
    if (witness > Task::ID_INDEX) CXXV_ASSERT(task->at(witness) == null_value, "clear each remaining task field");
  }
  // The backing storage belongs to this fixture. Heap teardown is checked separately.
  exit(0);
}
