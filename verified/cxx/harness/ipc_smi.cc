// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
static void observe_free(void* block) {
  CXXV_ASSERT(block == nullptr, "integer leaves never release owned storage");
}

#define free observe_free
#define protected public
#define private public
#include "ipc_scalar_messaging.inc"
#undef private
#undef protected
#undef free

using namespace toit;

LargeInteger* ObjectHeap::allocate_large_integer(int64) {
  CXXV_ASSERT(false, "a same-width tagged integer decodes without heap allocation");
  return nullptr;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  word value = nondet_word();
  CXXV_ASSUME(Smi::is_valid(value));
  auto* input = Smi::from(value);
  int depth = nondet_int();
  CXXV_ASSUME(depth >= 0 && depth < MESSAGING_ENCODING_MAX_NESTING);
  static_assert(MESSAGING_ENCODING_MAX_NESTING <= MESSAGING_DECODING_MAX_NESTING, "receiver admits every sender depth");

  MessageEncoder sizing(nullptr, nullptr);
  sizing.nesting_ = depth;
  bool sized = sizing.encode(input);
  word size = sizing.size();
  CXXV_ASSERT(sized && size >= 2 && size <= 1 + (WORD_BIT_SIZE + 6) / 7 &&
              sizing.total_size() == size && sizing.externals_count() == 0,
              "size a tagged integer with no external charge");
  uint8 storage[size];
  MessageEncoder writing(nullptr, storage, MESSAGE_FORMAT_IPC, false);
  writing.nesting_ = depth;
  bool written = writing.encode(input);
  CXXV_ASSERT(written && writing.size() == size && writing.total_size() == size &&
              writing.externals_count() == 0 && writing.transferred_count_ == 0 && writing.copied_count_ == 0,
              "write exactly the sized bytes without registering owners");
  CXXV_ASSERT(storage[0] == (value < 0 ? TAG_NEGATIVE_SMI : TAG_POSITIVE_SMI), "wire tag identifies sign");

  if (nondet_bool()) {
    MessageDecoder reader(nullptr, storage, size, MESSAGE_FORMAT_IPC);
    reader.nesting_ = depth;
    Object* result = reader.decode();
    CXXV_ASSERT(reinterpret_cast<uword>(result) == reinterpret_cast<uword>(input) &&
                reader.success() && reader.cursor_ == size && reader.externals_count() == 0,
                "decode the exact original integer and consume the complete leaf");
  } else {
    MessageDecoder cleanup(storage);
    cleanup.deallocate();
    CXXV_ASSERT(cleanup.success() && cleanup.cursor_ == size,
                "native disposal consumes exactly the measured integer");
  }
}
