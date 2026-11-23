// Copyright (C) 2026 Toit contributors.

#pragma once

#include <stdint.h>

#ifdef __cplusplus
namespace toit {
#endif

// A truncated string stops before the UTF-8 sequence straddling byte 255.
// Invalid input can have an arbitrarily long run of continuation bytes.
/*@ requires 0 <= length;
    requires length > 255 ==> \valid_read(data + (0 .. 255));
    terminates \true;
    assigns \nothing;
    ensures 0 <= \result <= 255;
    ensures length <= 255 ==> \result == length;
    ensures length > 255 && \result > 0 ==> !(128 <= data[\result] <= 191);
    ensures length > 255 ==> (\forall integer i; \result < i <= 255 ==> 128 <= data[i] <= 191);
*/
static inline int encoder_string_prefix(const uint8_t* data, intptr_t length) {
  if (length <= 255) return (int) length;
  int end = 255;
  /*@ loop invariant 0 <= end <= 255;
      loop invariant \forall integer i; end < i <= 255 ==> 128 <= data[i] <= 191;
      loop assigns end;
      loop variant end;
  */
  while (end > 0 && data[end] >= 0x80 && data[end] <= 0xbf) end--;
  return end;
}

#ifdef __cplusplus
}  // namespace toit
#endif
