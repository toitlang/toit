// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "third_party/dartino/object_memory_mark_sweep.cc"
#undef protected
#undef private

using namespace toit;

extern Program image;
extern CompactingVisitor visitor;
extern FixPointersVisitor fixer;
GcMetadata GcMetadata::singleton_;

constexpr unsigned SOURCE = 33;
constexpr unsigned LENGTH = 3;
alignas(TOIT_PAGE_SIZE) static uword heap_words[64];
static uword original[LENGTH], prior_used, destination;
static unsigned target, calls;
static uint8 starts[2], cards[2], original_start[2], original_card[2];

Chunk::Chunk(Space* owner, uword first, uword bytes)
    : owner_(owner), start_(first), end_(first + bytes), scavenge_pointer_(first) {}
Chunk::~Chunk() {}

word HeapObject::size(Program* program) const {
  CXXV_ASSERT(program == &image && _raw() == reinterpret_cast<uword>(&heap_words[SOURCE]),
              "measure the marked source object");
  return LENGTH * WORD_SIZE;
}

void HeapObject::roots_do(Program* program, RootCallback* callback) {
  ++calls;
  CXXV_ASSERT(program == &image && callback == &fixer && _raw() == destination &&
              visitor.dest_.address == destination && visitor.used_ == prior_used,
              "fix the destination before advancing the visitor");
  for (unsigned i = 0; i < LENGTH; ++i) {
    CXXV_ASSERT(heap_words[target + i] == original[i], "fix pointers only after all original words were copied");
  }
  for (unsigned i = 0; i < 2; ++i) {
    bool selected = i == target / 32;
    uint8 expected = selected && SOURCE != target && original_card[SOURCE / 32] != 0
        ? GcMetadata::NEW_SPACE_POINTERS : original_card[i];
    CXXV_ASSERT(cards[i] == expected && starts[i] == (selected ? static_cast<uint8>(destination) : original_start[i]),
                "publish the destination start and propagate the source dirty card before fixing roots");
  }
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS && GcMetadata::CARD_SIZE == 32 * WORD_SIZE, "card geometry");
  uword base = reinterpret_cast<uword>(heap_words);
  CXXV_ASSUME(base % GcMetadata::CARD_SIZE == 0 && base <= UINTPTR_MAX - sizeof(heap_words));
#ifdef CXXV_SWITCH
  CXXV_ASSUME(base % TOIT_PAGE_SIZE == 0 && base >= 2 * TOIT_PAGE_SIZE && base <= UINTPTR_MAX - TOIT_PAGE_SIZE);
  target = 0;
#else
  unsigned choice = nondet_uint() % 4;
  target = choice == 0 ? SOURCE : choice == 1 ? 32 : choice == 2 ? 31 : 1;
#endif
  destination = base + target * WORD_SIZE;
  for (unsigned i = 0; i < LENGTH; ++i) heap_words[SOURCE + i] = original[i] = nondet_ulong();
  for (unsigned i = 0; i < 2; ++i) {
    starts[i] = original_start[i] = nondet_uchar();
    cards[i] = original_card[i] = nondet_uchar();
  }
  uint32 marks[] = {0, 14};  // The three words starting at word 33 are live.
  auto& meta = GcMetadata::singleton_;
  meta.starts_bias_ = reinterpret_cast<uword>(starts) - base / GcMetadata::CARD_SIZE;
  meta.remembered_set_bias_ = reinterpret_cast<uword>(cards) - base / GcMetadata::CARD_SIZE;
  meta.mark_bits_bias_ = reinterpret_cast<uword>(marks) - (base >> GcMetadata::MARK_BITS_SHIFT);
  prior_used = nondet_ulong();
  CXXV_ASSUME(prior_used <= UINTPTR_MAX - LENGTH * WORD_SIZE);
  visitor.used_ = prior_used;
#ifdef CXXV_SWITCH
  // Two words remain in the current chunk, the next chunk is empty,
  // and the third chunk has an exact fit. Only its first words are used.
  Chunk previous(nullptr, base - 2 * TOIT_PAGE_SIZE, TOIT_PAGE_SIZE);
  Chunk empty(nullptr, base - TOIT_PAGE_SIZE, TOIT_PAGE_SIZE);
  Chunk active(nullptr, base, TOIT_PAGE_SIZE);
  ChunkList list;
  list.append(&previous);
  list.append(&empty);
  list.append(&active);
  empty.set_compaction_top(empty.start());
  active.set_compaction_top(destination + LENGTH * WORD_SIZE);
  visitor.dest_ = GcMetadata::Destination(list.begin(), previous.usable_end() - 2 * WORD_SIZE, previous.usable_end());
#else
  visitor.dest_.address = destination;
  visitor.dest_.limit = destination + LENGTH * WORD_SIZE;
#endif
  visitor.fix_pointers_visitor_ = &fixer;
  visitor.program_ = &image;
  uword size = visitor.CompactingVisitor::visit(HeapObject::from_address(base + SOURCE * WORD_SIZE));
#ifdef CXXV_SWITCH
  CXXV_ASSERT(visitor.dest_.chunk() == &active && visitor.dest_.limit == active.compaction_top(),
              "skip both unsuitable destinations and retain the selected chunk");
#endif
  CXXV_ASSERT(calls == 1 && size == LENGTH * WORD_SIZE && visitor.used_ == prior_used + size &&
              visitor.dest_.address == destination + size, "account for the visited object exactly once");
}
