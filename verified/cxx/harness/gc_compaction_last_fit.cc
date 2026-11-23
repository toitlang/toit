// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "objects.cc"
#include "third_party/dartino/gc_metadata.cc"
#undef protected
#undef private

using namespace toit;

alignas(256) static uword words[96];
extern Program image;
constexpr unsigned A = 35, B = 33, C = 27;
static const unsigned offsets[] = {0, A, A + B, A + B + C};
struct Header {
  bool sentinel;
  bool marked;
  uword destination;
  word size;
};
static Header headers[4];

// ESBMC can lose the backing pointer when it rereads a tagged header through
// an address computed by the walk. Check the numeric receiver and reuse the
// values read by the native accessors at that same address before the walk.
static Header* header_at(uword raw) {
  uword line = reinterpret_cast<uword>(words);
  for (unsigned i = 0; i < 4; ++i) {
    if (raw == line + offsets[i] * WORD_SIZE) return &headers[i];
  }
  CXXV_ASSERT(false, "each read selects an installed header or the chunk sentinel");
  abort();
}
static word checked_size(HeapObject* object, Program* program) {
  Header* header = header_at(object->_raw());
  CXXV_ASSERT(program == &image && !header->sentinel, "only objects have a size");
  return header->size;
}
class CheckedPlanner : public GcMetadata {
 public:
  static uword last_line_that_fits(Program*, uword, uword);
};
#include "compaction_last_fit.inc"

void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "only initialized instance and array headers are inspected");
  abort();
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  constexpr uword bytes = sizeof(words);
  uword line = reinterpret_cast<uword>(words);
  CXXV_ASSUME(line % 256 == 0 && line <= UINTPTR_MAX - bytes);

  // Two crossing objects and one object ending at the sentinel. Read the
  // instances' sizes from the image and the array's size from its header.
  constexpr unsigned a = A, b = B, c = C;
  uint16 classes[] = {(a << HeapObject::CLASS_ID_OFFSET) | INSTANCE_TAG, ARRAY_TAG,
                      (c << HeapObject::CLASS_ID_OFFSET) | INSTANCE_TAG};
  image.class_bits = List<uint16>(classes, 3);
  words[0] = INSTANCE_TAG << Object::SMI_TAG_SIZE;
  words[a] = ((1 << HeapObject::CLASS_ID_OFFSET) | ARRAY_TAG) << Object::SMI_TAG_SIZE;
  words[a + 1] = b - Array::allocation_size(0) / WORD_SIZE;
  words[a + b] = ((2 << HeapObject::CLASS_ID_OFFSET) | INSTANCE_TAG) << Object::SMI_TAG_SIZE;
  bool live_a = nondet_bool(), live_b = nondet_bool(), live_c = nondet_bool();
  uint32 marks[3] = {
    live_a ? UINT32_MAX : 0u,
    (live_a ? 7u : 0u) | (live_b ? ~7u : 0u),
    (live_b ? 15u : 0u) | (live_c ? 0x7ffffff0u : 0u)
  };
  uword base = nondet_ulong();
  CXXV_ASSUME(base % WORD_SIZE == 0 && base <= UINTPTR_MAX - bytes);
  uword counts[] = {base, base + (live_a ? 32 : 0) * WORD_SIZE,
                    base + ((live_a ? a : 0) + (live_b ? 29 : 0)) * WORD_SIZE};
  uint8 start = static_cast<uint8>(line);
  auto& meta = GcMetadata::singleton_;
  meta.starts_bias_ = reinterpret_cast<uword>(&start) - line / GcMetadata::CARD_SIZE;
  meta.mark_bits_bias_ = reinterpret_cast<uword>(marks) - (line >> GcMetadata::MARK_BITS_SHIFT);
  meta.cumulative_mark_bits_bias_ = reinterpret_cast<uword>(counts) - (line >> GcMetadata::CUMULATIVE_MARK_BITS_SHIFT);

  for (unsigned i = 0; i < 4; ++i) {
    uword raw = line + offsets[i] * WORD_SIZE;
    auto object = HeapObject::from_address(raw);
    headers[i].sentinel = has_sentinel_at(raw);
    headers[i].marked = GcMetadata::is_marked(object);
    headers[i].destination = GcMetadata::get_destination(object);
    if (i < 3) headers[i].size = object->size(&image);
  }
  uword capacity = nondet_ulong();
  CXXV_ASSUME(capacity <= 96 && (!live_a || a <= capacity));
  uword result = CheckedPlanner::last_line_that_fits(&image, line, base + capacity * WORD_SIZE);
  unsigned used = live_a ? a : 0;
  bool stop_b = live_b && used + b > capacity;
  if (live_b) used += b;
  bool stop_c = live_c && used + c > capacity;
  unsigned last = stop_b ? 0 : stop_c ? 1 : 2;
  CXXV_ASSERT(result == line + last * GcMetadata::CARD_SIZE,
              "return the card preceding the first overflowing live object or the card containing the sentinel");
  return 0;
}
