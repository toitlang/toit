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
  word length = nondet_word();
  CXXV_ASSUME(length >= 0 && length <= MESSAGING_ENCODING_MAX_SIZE);
  bool inlined = nondet_bool();
  CXXV_ASSUME(!inlined || length <= MESSAGING_ENCODING_MAX_INLINED_SIZE);
  uint8 tag = inlined ? TAG_BYTE_ARRAY_INLINE : TAG_BYTE_ARRAY;
  uint8* pointer = reinterpret_cast<uint8*>(nondet_ulong());
  word digits = 1;
  for (uword value = length; value >= 128; value >>= 7) ++digits;
  word prefix = 1 + digits;
  word extent = prefix + (inlined ? length : WORD_SIZE);
  uint8 storage[extent];
  bool sizing = nondet_bool();
  MessageEncoder encoder(nullptr, sizing ? nullptr : storage, MESSAGE_FORMAT_IPC, false);
  encoder.write_uint8(tag);
  CXXV_ASSERT(encoder.size() == 1, "the discriminator consumes one byte");
  encoder.write_cardinal(length);
  CXXV_ASSERT(encoder.size() == prefix, "tag and length leave the cursor at the payload");
  if (!inlined) {
    encoder.write_pointer(pointer);
    CXXV_ASSERT(encoder.size() == extent, "the pointer consumes exactly one word");
  }
  if (sizing) return 0;
  MessageDecoder reader(nullptr, storage, extent, MESSAGE_FORMAT_IPC);
  uint8 actual_tag = reader.read_uint8();
  uword actual_length = reader.read_cardinal();
  CXXV_ASSERT(actual_tag == tag && actual_length == static_cast<uword>(length) && reader.success() && reader.cursor_ == prefix,
              "recover the exact tag and length and reach the inline bytes or pointer");
  if (!inlined) {
    uint8* decoded = reader.read_pointer();
    CXXV_ASSERT(reinterpret_cast<uword>(decoded) == reinterpret_cast<uword>(pointer) && reader.success() && reader.cursor_ == extent,
                "preserve all pointer bits and end at the measured boundary");
  }
}
