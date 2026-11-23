// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "snapshot.h"
#include "objects_inline.h"
#include "program_heap.h"
#include "os.h"
#include "process.h"
#include "uuid.h"
#include "vm.h"

static uint8* source;
static uint8* destination;
static int payload, witness;
static bool copied;

// Observe a single arbitrary byte under the libc memcpy contract.
static void* copy_slice(void* dst, const void* src, size_t n) {
  CXXV_ASSERT(!copied && dst == destination && src == source && n == static_cast<size_t>(payload),
              "copy exactly the declared bytes into the external reservation");
  if (payload > 0) destination[witness] = source[witness];
  copied = true;
  return dst;
}
#define memcpy copy_slice
#include "snapshot.cc"
#undef memcpy
#undef protected
#undef private

using namespace toit;

class Reader : public SnapshotReader {
 public:
  Reader(uint8* data, int length, ImageAllocator* allocator) : SnapshotReader(data, length, allocator) {}
  bool read_header() override { return false; }
};

int main() {
  static_assert(CXXV_WORD_BITS == WORD_BIT_SIZE, "target width");
  int size = nondet_int(), pos = nondet_int();
  CXXV_ASSUME(size >= 0 && pos >= 0 && pos <= size);
  auto* input = static_cast<uint8*>(malloc(static_cast<size_t>(size) + 1));
  CXXV_ASSUME(input != nullptr);
  payload = nondet_int();
  // The host snapshot encodes int32 lengths in native byte order.
  bool complete = size - pos >= 4;
  if (complete) memcpy(input + pos, &payload, sizeof(payload));
  int after_length = complete ? pos + 4 : size;
  source = input + after_length;
  int capacity = nondet_int();
  CXXV_ASSUME(capacity >= 0 && capacity % WORD_SIZE == 0);
  auto* arena = static_cast<uint8*>(malloc(static_cast<size_t>(capacity) + WORD_SIZE));
  CXXV_ASSUME(arena != nullptr && reinterpret_cast<uword>(arena) % WORD_SIZE == 0);
  int used = nondet_int();
  CXXV_ASSUME(used >= 0 && used <= capacity && used % WORD_SIZE == 0);
  destination = arena + used;
  ImageAllocator allocator;
  allocator.external_top_ = destination;
  allocator.external_end_ = arena + capacity;
  Reader reader(input, size, &allocator);
  reader.pos_ = pos;
  bool fits = complete && payload >= 0 && payload <= size - after_length && payload <= capacity - used;
  witness = 0;
  uint8 expected = nondet_uchar();
  if (fits && payload > 0) {
    witness = nondet_int();
    CXXV_ASSUME(0 <= witness && witness < payload);
    source[witness] = expected;
  }
  List<uint8> view = reader.read_external_list_uint8();
  CXXV_ASSERT(copied == fits && reader.failed() == !fits, "only a complete in-bounds table is published");
  if (fits) {
    CXXV_ASSERT(view.data() == destination && view.length() == payload && reader.pos_ == after_length + payload,
                "the returned table and consumed input have exactly the declared extent");
    if (payload > 0) CXXV_ASSERT(view[witness] == expected, "the published byte is the corresponding snapshot byte");
  } else {
    CXXV_ASSERT(view.data() == nullptr && view.length() == 0 && reader.pos_ == after_length &&
                allocator.external_top_ == destination, "reject the table without publishing or consuming its payload");
  }
}
