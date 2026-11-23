// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define protected public
#define private public
#include "messaging.cc"
#undef private
#undef protected

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  constexpr word max_digits = (WORD_BIT_SIZE + 6) / 7;
  uword value = nondet_ulong();
  MessageEncoder sizing(nullptr, nullptr);
  sizing.write_cardinal(value);
  word length = sizing.size();
  CXXV_ASSERT(length >= 1 && length <= max_digits, "sizing includes one to ten base-128 digits");
  uint8 storage[length];
  MessageEncoder writer(nullptr, storage, MESSAGE_FORMAT_IPC, false);
  writer.write_cardinal(value);
  CXXV_ASSERT(writer.size() == length, "write into exactly the measured extent");
  MessageDecoder reader(nullptr, storage, length, MESSAGE_FORMAT_IPC);
  uword decoded = reader.read_cardinal();
  CXXV_ASSERT(reader.success() && decoded == value && reader.cursor_ == length,
              "read the original word and stop at the end of its field");
  // Check every position in the output with an arbitrary digit index.
  word index = nondet_word();
  CXXV_ASSUME(index >= 0 && index < length);
  uword remaining = value >> (7 * index);
  uint8 digit = storage[index];
  CXXV_ASSERT((digit & 127) == (remaining & 127), "each digit carries the corresponding seven bits");
  CXXV_ASSERT((digit >= 128) == (index + 1 < length) &&
              (digit >= 128) == (remaining >= 128), "continue exactly while higher bits remain");
  CXXV_ASSERT(index == 0 || remaining != 0, "noninitial digits never encode a redundant leading zero");
}
