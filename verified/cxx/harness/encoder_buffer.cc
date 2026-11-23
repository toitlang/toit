// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "encoder.h"
#undef private

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  word capacity = nondet_word();
  CXXV_ASSUME(capacity > 0);
  MallocedBuffer buffer(capacity);
  uint8* storage = buffer.content();
  word length = storage == nullptr ? 0 : capacity;
  CXXV_ASSERT(buffer.has_content() == (storage != nullptr) && buffer.size() == 0 &&
              buffer.has_overflow() == (length == 0), "initial state reflects allocation");
  CXXV_ASSERT(buffer.length_ == length, "usable capacity equals allocated size");

  // Induction step after any number of writes, including counting passes.
  word position = nondet_word();
  CXXV_ASSUME(position >= 0);
  buffer.pos_ = position;
  word index = nondet_word();
  uint8 before = nondet_uchar();
  if (length > 0) {
    CXXV_ASSUME(index >= 0 && index < length);
    storage[index] = before;
  }
  uint8 value = nondet_uchar();
  buffer.put_byte(value);
  word next = position == INTPTR_MAX ? position : position + 1;
  CXXV_ASSERT(buffer.size() == next && buffer.has_overflow() == (next >= length),
              "count attempted bytes up to the word limit and flag a full buffer");
  CXXV_ASSERT(buffer.content() == storage && buffer.length_ == length, "preserve backing storage");
  if (length > 0) {
    CXXV_ASSERT(storage[index] == (index == position ? value : before),
                "write exactly the addressed byte when it fits");
  }
  if (nondet_bool()) {
    uint8* taken = buffer.take_content();
    CXXV_ASSERT(taken == storage && buffer.content() == nullptr && !buffer.has_content() &&
                buffer.has_overflow() && buffer.size() == next, "transfer storage and preserve size");
    free(taken);
  }
}
