// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
static void* reserve_bytes(size_t);
static void release_bytes(void*);
#define private public
#define protected public
#define malloc reserve_bytes
#define free release_bytes
#include "process.h"
#undef malloc
#undef free
#include "process.cc"
#include "interpreter_v2.cc"
#undef protected
#undef private

using namespace toit;
extern Process process_under_test;
extern String string_header;
extern ByteArray array_header;
static word length, quota, cost, charged;
static bool string;
static uint8* memory;
static bool malloc_fails, header_fails;
static unsigned internal, external, limits, requests, releases, charges, refunds;

static void* reserve_bytes(size_t n) {
  CXXV_ASSERT(limits == 1 && cost >= 0 && cost <= quota && !requests &&
              n == static_cast<uword>(cost == 0 ? 1 : cost),
              "reserve the admitted storage, including padding for an empty external array");
  ++requests;
  if (malloc_fails) return nullptr;
  memory = static_cast<uint8*>(malloc(n));
  CXXV_ASSUME(memory != nullptr);
  if (string) memory[length] = 42;
  return memory;
}
static void release_bytes(void* p) {
  CXXV_ASSERT(p == memory && charged == cost && !releases && external && header_fails,
              "release the reserved bytes on header failure");
  ++releases;
  free(p);
}

word ObjectHeap::max_external_allocation() {
  CXXV_ASSERT(this == process_under_test.object_heap(), "consult the requesting process quota");
  ++limits;
  return quota;
}
void ObjectHeap::register_external_allocation(word n) {
  CXXV_ASSERT(this == process_under_test.object_heap() && memory && n == cost && !charges, "charge the complete reservation");
  ++charges;
  charged = n;
}
void ObjectHeap::unregister_external_allocation(word n) {
  CXXV_ASSERT(this == process_under_test.object_heap() && releases == 1 && n == charged && !refunds, "refund the same reservation");
  ++refunds;
  charged = 0;
}
String* ObjectHeap::allocate_internal_string(word n) {
  CXXV_ASSERT(this == process_under_test.object_heap() && string && n == length && !internal, "pass the original length to internal allocation");
  ++internal;
  return header_fails ? nullptr : &string_header;
}
String* ObjectHeap::allocate_external_string(word n, uint8* p, bool dispose) {
  CXXV_ASSERT(this == process_under_test.object_heap() && string && n == length && p == memory && p[n] == 0 &&
              charged == n + 1 && dispose && !external, "publish the terminated, charged buffer with disposal enabled");
  ++external;
  return header_fails ? nullptr : &string_header;
}

ByteArray* ObjectHeap::allocate_internal_byte_array(word n) {
  CXXV_ASSERT(this == process_under_test.object_heap() && !string && n == length && !internal,
              "pass the original array length to internal allocation");
  ++internal;
  return header_fails ? nullptr : &array_header;
}
ByteArray* ObjectHeap::allocate_external_byte_array(word n, uint8* p, bool dispose, bool clear) {
  CXXV_ASSERT(this == process_under_test.object_heap() && !string && n == length && p == memory &&
              charged == n && dispose && clear && !external, "request a cleared, owned external array of the charged length");
  ++external;
  return header_fails ? nullptr : &array_header;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  length = nondet_word();
  quota = nondet_word();
  malloc_fails = nondet_bool();
  header_fails = nondet_bool();
  string = nondet_bool();
  bool from_core = nondet_bool();
  bool force_external = !from_core && nondet_bool();
  bool valid = length >= 0 && (!string || length < INTPTR_MAX);
  cost = valid ? length + int(string) : -1;
  HeapObject* result;
  HeapObject* expected;
  if (string) {
    result = from_core
        ? reinterpret_cast<HeapObject*>(toit_v2_try_allocate_string(&process_under_test, static_cast<uword>(length)))
        : process_under_test.allocate_string(length);
    expected = &string_header;
  } else {
    result = from_core
        ? reinterpret_cast<HeapObject*>(toit_v2_try_allocate_byte_array(&process_under_test, static_cast<uword>(length)))
        : process_under_test.allocate_byte_array(length, force_external);
    expected = &array_header;
  }
  bool in_heap = valid && (string ? length <= String::max_internal_size_in_process() :
                           !force_external && length <= ByteArray::max_internal_size_in_process());
  bool outside = valid && !in_heap;
  bool admitted = outside && cost <= quota;
  bool allocated = admitted && !malloc_fails;
  bool published = allocated && !header_fails;
  CXXV_ASSERT(internal == unsigned(in_heap) && limits == unsigned(outside) &&
              requests == unsigned(admitted) && external == unsigned(allocated), "select exactly the valid allocation path");
  CXXV_ASSERT(result == ((in_heap && !header_fails) || published ? expected : nullptr),
              "report allocation failure or the actual resulting header");
  CXXV_ASSERT(charges == unsigned(allocated) && refunds == unsigned(allocated && header_fails) &&
              releases == refunds && charged == (published ? cost : 0), "balance ownership and quota on every return");
  if (published) free(memory);  // The modeled VM header owns the payload at return.
}
