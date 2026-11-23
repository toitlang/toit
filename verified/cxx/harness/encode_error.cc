// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
static void* buffer_malloc(size_t);
static void buffer_free(void*);
#define malloc buffer_malloc
#define free buffer_free
#define private public
#include "encoder.h"
#undef free
#undef malloc
#include "objects_inline.h"
#include "scheduler.h"
#include "process.h"
#undef private

using std::fpclassify;  // Used unqualified by an unrelated primitive in this translation unit.
static void* result_copy(void*, const void*, size_t);
#define memcpy result_copy
#include "primitive_core.cc"
#undef memcpy

using namespace toit;

extern Process caller;
extern Program image;
extern SchedulerThread thread;
static Object* args[2];
static uword task_words[2];
static uword stack_header = 2 * STACK_TAG;
static Stack* saved_stack;
static unsigned phase;
static word produced;
static word witness;
static uint8 value;
static bool failed_allocation;
static uint8* source;
static unsigned buffer_requests;
static bool buffer_allocated;
static unsigned releases;
static uint8* destination;
static ByteArray* result_array;
static void* array_storage;
static void* external_storage;

static void* buffer_malloc(size_t size) {
  CXXV_ASSERT(phase == 0 && size == STACK_ENCODING_BUFFER_SIZE, "request the configured native buffer first");
  ++buffer_requests;
  source = static_cast<uint8*>(malloc(size));
  buffer_allocated = source != nullptr;
  return source;
}

static void buffer_free(void* ptr) {
  CXXV_ASSERT(ptr == source, "release the original native allocation");
  ++releases;
  free(ptr);
  source = nullptr;
}

ProgramOrientedEncoder::ProgramOrientedEncoder(Program* p, Buffer* b) : Encoder(b), program_(p) {
  auto* out = static_cast<MallocedBuffer*>(b);
  CXXV_ASSERT(phase == 0 && p == &image && out->has_content() &&
              out->content() == source && out->length_ == STACK_ENCODING_BUFFER_SIZE && out->size() == 0,
              "start the encoder only with a live buffer of the configured capacity");
  ++phase;
}

void Interpreter::store_stack(Object** sp, Method pending) {
  CXXV_ASSERT(phase == 1 && this == thread.interpreter() && sp == nullptr && !pending.is_valid(),
              "store the calling interpreter stack before encoding");
  task_words[1] = reinterpret_cast<uword>(saved_stack);
  ++phase;
}

bool ProgramOrientedEncoder::encode_error(Object* type, Object* message, Stack* stack) {
  CXXV_ASSERT(phase == 2 && type == args[1] && message == args[0] && stack == saved_stack,
              "encode the two arguments in order with the newly stored stack");
  auto* out = static_cast<MallocedBuffer*>(buffer());
  out->pos_ = produced;
  if (witness < produced && witness < out->length_) source[witness] = value;
  ++phase;
  return !out->has_overflow();
}

Object** Interpreter::load_stack(Method* pending) {
  CXXV_ASSERT(phase == 3 && this == thread.interpreter() && pending == nullptr,
              "reload the same interpreter stack on either encoding outcome");
  ++phase;
  return nullptr;
}

ByteArray* Process::allocate_byte_array(word length, bool force_external) {
  CXXV_ASSERT(phase == 4 && this == &caller && length == produced &&
              length < STACK_ENCODING_BUFFER_SIZE && !force_external,
              "request exactly the encoded byte count after a successful traversal and reload");
  ++phase;
  if (failed_allocation) return nullptr;
  bool external = nondet_bool();
  array_storage = malloc(external ? 4 * sizeof(word) : 2 * sizeof(word) + length);
  CXXV_ASSUME(array_storage != nullptr);
  auto* words = static_cast<uword*>(array_storage);
  words[0] = 2 * BYTE_ARRAY_TAG;
  words[1] = external ? static_cast<uword>(-1 - length) : static_cast<uword>(length);
  if (external) {
    external_storage = malloc(length == 0 ? 1 : length);
    CXXV_ASSUME(external_storage != nullptr);
    words[2] = reinterpret_cast<uword>(external_storage);
    words[3] = RawByteTag;
  }
  destination = external ? static_cast<uint8*>(external_storage) : reinterpret_cast<uint8*>(words + 2);
  result_array = static_cast<ByteArray*>(HeapObject::from_address(reinterpret_cast<uword>(words)));
  return result_array;
}

// Observe memcpy's contract at an arbitrary byte of its nonoverlapping ranges.
static void* result_copy(void* dst, const void* src, size_t length) {
  CXXV_ASSERT(phase == 5 && dst == destination && src == source && length == static_cast<size_t>(produced),
              "copy from the native buffer into the actual result payload at its exact size");
  ++phase;
  if (witness < produced) static_cast<uint8*>(dst)[witness] = static_cast<const uint8*>(src)[witness];
  return dst;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  caller.program_ = &image;
  caller.scheduler_thread_ = &thread;
  task_words[0] = 2 * TASK_TAG;
  caller.object_heap()->task_ = static_cast<Task*>(HeapObject::from_address(reinterpret_cast<uword>(task_words)));
  saved_stack = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(&stack_header)));
  produced = nondet_word();
  witness = nondet_word();
  CXXV_ASSUME(produced >= 0 && witness >= 0);
  value = nondet_uchar();
  failed_allocation = nondet_bool();
  args[0] = reinterpret_cast<Object*>(nondet_ulong());
  args[1] = reinterpret_cast<Object*>(nondet_ulong());
  Object* frame[] = {args[0], args[1]};
  Object* result = primitive_encode_error(&caller, frame + 1);
  int error = -1;
  unsigned expected_phase = 6;
  if (!buffer_allocated) {
    error = Program::MALLOC_FAILED_INDEX;
    expected_phase = 0;
  } else if (produced >= STACK_ENCODING_BUFFER_SIZE) {
    error = Program::OUT_OF_BOUNDS_INDEX;
    expected_phase = 4;
  } else if (failed_allocation) {
    error = Program::ALLOCATION_FAILED_INDEX;
    expected_phase = 5;
  }
  Object* expected = error < 0 ? static_cast<Object*>(result_array) :
      reinterpret_cast<Object*>((static_cast<uword>(error) << Error::ERROR_SHIFT) | Error::ERROR_TAG);
  CXXV_ASSERT(buffer_requests == 1 && releases == 1, "one native buffer request and destructor on every return");
  CXXV_ASSERT(phase == expected_phase && result == expected, "exact result and call sequence on all four outcomes");
  CXXV_ASSERT(frame[0] == args[0] && frame[1] == args[1], "preserve the argument frame");
  if (error < 0 && witness < produced) CXXV_ASSERT(destination[witness] == value, "every result byte matches the encoding");
  free(external_storage);
  free(array_storage);
}
