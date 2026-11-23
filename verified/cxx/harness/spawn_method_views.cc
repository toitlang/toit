// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "objects.h"

using namespace toit;

extern uint8* arbitrary_byte_pointer();

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uint8* data = arbitrary_byte_pointer();
  word length = nondet_word();
  CXXV_ASSUME(length >= 0);
  const List<uint8> bytecodes(data, length);
  CXXV_ASSERT(bytecodes.data() == data, "const bytecode view returns its original pointer");
  CXXV_ASSERT(bytecodes.length() == length, "const bytecode view returns its original length");

  const Method stored(data);
  Method method = stored;
  CXXV_ASSERT(method.header_bcp() == data && method.is_valid() == (data != nullptr),
              "copying a spawn method preserves the header pointer and validity");
}
