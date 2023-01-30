// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include "../../src/top.h"
#include "../../src/utils.h"

void fatal(int line) {
  fprintf(stderr, "FATAL at line %d\n", line);
  FATAL(FATAL);
}

namespace toit {

#define AELIG 0xe6
#define EURO 0x20ac
#define CAT_WITH_TEARS_OF_JOY_1 0xD83D
#define CAT_WITH_TEARS_OF_JOY_2 0xDE39

void test_utf_16_to_8() {
  // Plain ASCII.
  uint16 x[1] = {'x'};
  if (Utils::utf_16_to_8(x, 1) != 1) fatal(__LINE__);
  // Basic plane.
  uint16 y[3] = {'x', AELIG, EURO};
  if (Utils::utf_16_to_8(y, 3) != 6) fatal(__LINE__);
  char out[10];
  out[6] = '\0';
  if (Utils::utf_16_to_8(y, 2, (uint8*)out, 2) != -1) fatal(__LINE__);
  if (Utils::utf_16_to_8(y, 2, (uint8*)out, 3) != 3) fatal(__LINE__);
  if (Utils::utf_16_to_8(y, 3, (uint8*)out, 7) != 6) fatal(__LINE__);
  if (strcmp(out, "xæ€")) fatal(__LINE__);
  // Surrogate pairs.
  uint16 z[4] = {'x', CAT_WITH_TEARS_OF_JOY_1, CAT_WITH_TEARS_OF_JOY_2, 'y'};
  if (Utils::utf_16_to_8(z, 4) != 6) fatal(__LINE__);
  if (Utils::utf_16_to_8(z, 4, (uint8*)out, 6) != 6) fatal(__LINE__);
  if (strcmp(out, "x😹y")) fatal(__LINE__);
  // Not enough space for output.
  if (Utils::utf_16_to_8(z, 4, (uint8*)out, 5) != -1) fatal(__LINE__);
  if (Utils::utf_16_to_8(z, 3, (uint8*)out, 6) != 5) fatal(__LINE__);
  if (Utils::utf_16_to_8(z, 3, (uint8*)out, 5) != 5) fatal(__LINE__);
  if (Utils::utf_16_to_8(z, 3, (uint8*)out, 4) != -1) fatal(__LINE__);
  // Half of a surrogate pair at the end.
  if (Utils::utf_16_to_8(z, 2) != 4) fatal(__LINE__);
  out[4] = '\0';
  if (Utils::utf_16_to_8(z, 2, (uint8*)out, 4) != 4) fatal(__LINE__);
  if (strcmp(out, "x�")) fatal(__LINE__);
  // Two high surrogates.
  z[2] = CAT_WITH_TEARS_OF_JOY_1;
  if (Utils::utf_16_to_8(z, 4) != 8) fatal(__LINE__);
  // Two low surrogates.
  z[1] = z[2] = CAT_WITH_TEARS_OF_JOY_2;
  if (Utils::utf_16_to_8(z, 4) != 8) fatal(__LINE__);
  out[8] = '\0';
  if (Utils::utf_16_to_8(z, 4, (uint8*)out, 8) != 8) fatal(__LINE__);
  if (strcmp(out, "x��y")) fatal(__LINE__);
  if (Utils::utf_16_to_8(z, 4, (uint8*)out, 7) != -1) fatal(__LINE__);
  if (Utils::utf_16_to_8(z, 3, (uint8*)out, 7) != 7) fatal(__LINE__);
  if (Utils::utf_16_to_8(z, 2, (uint8*)out, 4) != 4) fatal(__LINE__);
  if (Utils::utf_16_to_8(z, 2, (uint8*)out, 3) != -1) fatal(__LINE__);
}

void test_utf_8_to_16() {
  const char* in = "xæ€😹y";
  uint16 out[16];
  if (Utils::utf_8_to_16((const uint8*)in, 11, out, 6) != 6) fatal(__LINE__);
  if (Utils::utf_8_to_16((const uint8*)in, 11, out, 5) != -1) fatal(__LINE__);
  if (Utils::utf_8_to_16((const uint8*)in, 10, out, 5) != 5) fatal(__LINE__);
  if (Utils::utf_8_to_16((const uint8*)in, 10, out, 4) != -1) fatal(__LINE__);
  if (Utils::utf_8_to_16((const uint8*)in, 6, out, 3) != 3) fatal(__LINE__);
  if (Utils::utf_8_to_16((const uint8*)in, 6, out, 2) != -1) fatal(__LINE__);
  if (Utils::utf_8_to_16((const uint8*)in, 3, out, 2) != 2) fatal(__LINE__);
  if (Utils::utf_8_to_16((const uint8*)in, 3, out, 1) != -1) fatal(__LINE__);
  if (Utils::utf_8_to_16((const uint8*)in, 1, out, 1) != 1) fatal(__LINE__);
  if (Utils::utf_8_to_16((const uint8*)in, 1, out, 0) != -1) fatal(__LINE__);
  if (Utils::utf_8_to_16((const uint8*)in, 11) != 6) fatal(__LINE__);
  if (Utils::utf_8_to_16((const uint8*)in, 10) != 5) fatal(__LINE__);
  if (Utils::utf_8_to_16((const uint8*)in, 6) != 3) fatal(__LINE__);
  if (Utils::utf_8_to_16((const uint8*)in, 3) != 2) fatal(__LINE__);
  if (Utils::utf_8_to_16((const uint8*)in, 1) != 1) fatal(__LINE__);
  Utils::utf_8_to_16((const uint8*)in, 11, out, 6);
  if (out[0] != 'x') fatal(__LINE__);
  if (out[1] != AELIG) fatal(__LINE__);
  if (out[2] != EURO) fatal(__LINE__);
  if (out[3] != CAT_WITH_TEARS_OF_JOY_1) fatal(__LINE__);
  if (out[4] != CAT_WITH_TEARS_OF_JOY_2) fatal(__LINE__);
  if (out[5] != 'y') fatal(__LINE__);
}

void test_equals() {
  const uint8* str_8 = reinterpret_cast<const uint8*>("xæ€😹y");
  const uint16 str_16[6] = {'x', AELIG, EURO, CAT_WITH_TEARS_OF_JOY_1, CAT_WITH_TEARS_OF_JOY_2, 'y'};
  if (!Utils::utf_8_equals_utf_16(str_8, 11, str_16, 6)) fatal(__LINE__);         // Full comparison.
  if (Utils::utf_8_equals_utf_16(str_8, 10, str_16, 6)) fatal(__LINE__);          // UTF-8 is too short.
  if (Utils::utf_8_equals_utf_16(str_8, 11, str_16, 5)) fatal(__LINE__);          // UTF-16 is too short.
  if (Utils::utf_8_equals_utf_16(str_8 + 1, 2, str_16, 1)) fatal(__LINE__);       // Compare æ with x.
  if (Utils::utf_8_equals_utf_16(str_8, 1, str_16 + 1, 1)) fatal(__LINE__);       // Compare x with æ.
  if (!Utils::utf_8_equals_utf_16(str_8 + 1, 2, str_16 + 1, 1)) fatal(__LINE__);  // Compare æ with æ.
  const uint8* str_8z = reinterpret_cast<const uint8*>("xæ€😹z");                 // Last char does not match.
  if (Utils::utf_8_equals_utf_16(str_8z, 11, str_16, 6)) fatal(__LINE__);         // Full comparison.
  if (!Utils::utf_8_equals_utf_16(str_8z, 10, str_16, 5)) fatal(__LINE__);        // Omit last char.
}

int main(int argc, char **argv) {
  test_utf_16_to_8();
  test_utf_8_to_16();
  test_equals();
  return 0;
}

} // namespace toit

int main(int argc, char** argv) {
  return toit::main(argc, argv);
}
