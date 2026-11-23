// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "third_party/dartino/object_memory_copying.cc"
using namespace toit;

static Object* arena[10];
static Object* instance_header;

// The only legal clone destinations are the matching two-word slots in the
// other half of the arena. Check the memcpy contract and apply its effect.
static void copy_instance(void* target, const void* source, size_t bytes) {
  CXXV_ASSERT(bytes == 2 * WORD_SIZE, "clone requests both instance words");
  if (source == arena) {
    CXXV_ASSERT(target == arena + 5, "the root uses the first destination slot");
    arena[5] = arena[0];
    arena[6] = arena[1];
  } else {
    CXXV_ASSERT(source == arena + 2 && target == arena + 7, "a discovered neighbor uses the next disjoint slot");
    arena[7] = arena[2];
    arena[8] = arena[3];
  }
}
#define memcpy copy_instance
#include "third_party/dartino/two_space_heap.cc"
#undef memcpy
#undef protected
#undef private

extern TwoSpaceHeap heap;
extern Program image;
GcMetadata GcMetadata::singleton_;
Chunk::Chunk(Space* s, uword start, uword size)
    : owner_(s), start_(start), end_(start + size), scavenge_pointer_(start) {}
Chunk::~Chunk() {}
void Chunk::set_owner(Space* s) { owner_ = s; }
Space::~Space() {}
uword OldSpace::allocate(uword) {
  CXXV_ASSERT(false, "objects above the water mark stay in young space");
  return 0;
}
void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "the supplied instance graph has valid headers and fields");
  abort();
}

// gc-object-size and gc-object-roots verify these dispatch contracts. Check
// their representation preconditions each time the collector uses them.
word HeapObject::size(Program* program) const {
  CXXV_ASSERT(program == &image && _at(HEADER_OFFSET) == instance_header, "measure an intact two-word instance");
  return 2 * WORD_SIZE;
}

void HeapObject::roots_do(Program* program, RootCallback* cb) {
  CXXV_ASSERT(program == &image && _at(HEADER_OFFSET) == instance_header, "enumerate an intact instance");
  if (this == HeapObject::from_address(reinterpret_cast<uword>(arena + 5))) {
    cb->do_roots(arena + 6, 1);
  } else {
    CXXV_ASSERT(this == HeapObject::from_address(reinterpret_cast<uword>(arena + 7)), "scan only survivor fields");
    cb->do_roots(arena + 8, 1);
  }
}

static Object* choose_edge(HeapObject* first, HeapObject* second, Object* scalar) {
  return nondet_bool() ? first : nondet_bool() ? second : scalar;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  constexpr uword bytes = 5 * WORD_SIZE;  // Two instances and the end sentinel.
  uword source = reinterpret_cast<uword>(arena);
  uword target = reinterpret_cast<uword>(arena + 5);
  Chunk original(nullptr, source, bytes), survivor(nullptr, target, bytes);
  new (heap.new_space()) SemiSpace(&image, &original);
  heap.water_mark_ = source;
  ScavengeVisitor visitor(&image, &heap, &survivor);
  uint16 classes[] = {Program::compute_class_bits(INSTANCE_TAG, 2 * WORD_SIZE)};
  image.class_bits = List<uint16>(classes, 1);
  auto a = HeapObject::from_address(source);
  auto b = HeapObject::from_address(source + 2 * WORD_SIZE);
  a->_set_header(Smi::from(0), INSTANCE_TAG);
  b->_set_header(Smi::from(0), INSTANCE_TAG);
  heap.new_space()->top_ = source + 4 * WORD_SIZE;
  heap.new_space()->flush();
  Object* scalar = Smi::from(7);
  Object* a_edge = arena[1] = choose_edge(a, b, scalar);
  Object* b_edge = arena[3] = choose_edge(a, b, scalar);
  instance_header = arena[0];
  Object* root = a;
  visitor.do_roots(&root, 1);
  SemiSpace* to = visitor.to_space();
  CXXV_ASSERT(scan_copied_chunk(&image, &visitor, &survivor), "visit the copied root and any newly reachable instance");
  bool reaches_b = a_edge == b;
  auto moved_a = HeapObject::from_address(target);
  auto moved_b = HeapObject::from_address(target + 2 * WORD_SIZE);
  CXXV_ASSERT(root == moved_a && a->forwarding_address() == moved_a && arena[5] == instance_header,
              "publish the copied root and preserve its class");
  CXXV_ASSERT(arena[6] == (a_edge == a ? moved_a : reaches_b ? moved_b : scalar),
              "the root field preserves its edge under relocation");
  if (reaches_b) {
    CXXV_ASSERT(b->forwarding_address() == moved_b && arena[7] == instance_header &&
                arena[8] == (b_edge == a ? moved_a : b_edge == b ? moved_b : scalar),
                "a newly discovered instance preserves back edges, self edges and scalar fields");
  } else {
    CXXV_ASSERT(arena[2] == instance_header, "the unreachable instance retains its original header");
  }
  uword end = target + (reaches_b ? 4 : 2) * WORD_SIZE;
  CXXV_ASSERT(to->top_ == end && survivor.scavenge_pointer() == end && has_sentinel_at(end),
              "allocate and scan exactly the reachable instances");
}
