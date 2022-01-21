// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

validate format object result:
  expect_equals result (string.format format object)

failure format object error_string:
  expect_error error_string: (string.format format object)

expect_error str [code]:
  msg := (catch code).stringify
  print msg
  expect (msg.index_of str) != -1

main:
  validate "s"  12 "12"
  validate "d"  12 "12"
  validate "s" "12" "12"

  failure "" 12 "MISSING_TYPE_IN_FORMAT"
  failure "5" 12 "MISSING_TYPE_IN_FORMAT"
  failure "5i" 12 "WRONG_TYPE_IN_FORMAT"  // Use 'd' for decimals.
  failure "5dx" 12 "UNEXPECTED_TRAILING_CHARACTERS_IN_FORMAT"
  failure "5d " 12 "UNEXPECTED_TRAILING_CHARACTERS_IN_FORMAT"
  failure "5.d " 12 "MISSING_PRECISION_IN_FORMAT"
  failure "5.d " 12 "MISSING_PRECISION_IN_FORMAT"

  // Zero pad instead of space-pad if the pad width has a leading zero.
  // this only makes sense and works for right alignment.
  validate "-6s" 12 "12    "
  failure "-06s" 12 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  validate "6s" 12 "    12"
  validate "06s" 12 "000012"
  validate "^6s" 12 "  12  "
  failure "^06s" 12 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"

  validate "x" 15 "f"
  validate "-3x" 15 "f  "
  failure "-03x" 15 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  validate "3x" 15 "  f"
  validate "03x" 15 "00f"
  validate "^3x" 15 " f "
  failure "^03x" 15 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  validate "x" -1 "ffffffffffffffff"
  validate "x" -2 "fffffffffffffffe"
  validate "x" 4294967296 "100000000"
  validate "x" -4294967296 "ffffffff00000000"
  validate "x" 2147483648 "80000000"
  validate "x" -2147483648 "ffffffff80000000"
  validate "x" 2147483647 "7fffffff"
  validate "x" -2147483647 "ffffffff80000001"

  validate "X" 15 "F"
  validate "-3X" 15 "F  "
  failure "-03X" 15 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  validate "3X" 15 "  F"
  validate "03X" 15 "00F"
  validate "^3X" 15 " F "
  failure "^03X" 15 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  validate "X" -1 "FFFFFFFFFFFFFFFF"
  validate "X" -2 "FFFFFFFFFFFFFFFE"
  validate "X" 4294967296 "100000000"
  validate "X" -4294967296 "FFFFFFFF00000000"
  validate "X" 2147483648 "80000000"
  validate "X" -2147483648 "FFFFFFFF80000000"
  validate "X" 2147483647 "7FFFFFFF"
  validate "X" -2147483647 "FFFFFFFF80000001"

  validate "o" 15 "17"
  validate "-4o" 15 "17  "
  failure "-04o" 15 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  validate "4o" 15 "  17"
  validate "04o" 15 "0017"
  validate "^4o" 15 " 17 "
  failure "^04o" 15 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  validate "o" -1 "1777777777777777777777"
  validate "o" -2 "1777777777777777777776"
  validate "o" 4294967296 "40000000000"
  validate "o" -4294967296 "1777777777740000000000"
  validate "o" 2147483648 "20000000000"
  validate "o" -2147483648 "1777777777760000000000"
  validate "o" 2147483647 "17777777777"
  validate "o" -2147483647 "1777777777760000000001"

  validate "-6d" 12 "12    "
  failure "-06d" 12 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  validate "6d" 12 "    12"
  validate "06d" 12 "000012"
  validate "^6d" 12 "  12  "
  failure "^06d" 12 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"

  validate ".3f" 12.34 "12.340"
  validate ".1f" 12.34 "12.3"
  validate "5.1f" 12.34 " 12.3"
  validate "05.1f" 12.34 "012.3"
  validate "^8.1f" 12.34 "  12.3  "
  failure "^08.1f" 12.34 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"

  validate "s" "fisk" "fisk"
  validate "-6s" "fisk" "fisk  "
  failure "-06s" "fisk" "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  validate "6s" "fisk" "  fisk"
  validate "06s" "fisk" "00fisk"
  validate "^6s" "fisk" " fisk "
  failure "^06s" "fisk" "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"

  validate "c" 65 "A"
  validate "-6c" 65 "A     "
  failure "-06c" 65 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  validate "6c" 65 "     A"
  validate "06c" 65 "00000A"
  validate "^6c" 65 "  A   "
  failure "^06c" 65 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  validate "c" 230 "æ"
  validate "s" "æ" "æ"
  validate "-6c" 230 "æ     "
  validate "-6s" "æ" "æ     "
  failure "-06c" 230 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  validate "6c" 230 "     æ"
  validate "6s" "æ" "     æ"
  validate "06c" 230 "00000æ"
  validate "06s" "æ" "00000æ"
  validate "^6c" 230 "  æ   "
  validate "^6s" "æ" "  æ   "
  failure "^06c" 230 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  validate "c" 9731 "☃"
  validate "s" "☃" "☃"
  validate "-6c" 9731 "☃     "
  validate "-6s" "☃" "☃     "
  failure "-06c" 9731 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  validate "6c" 9731 "     ☃"
  validate "6s" "☃" "     ☃"
  validate "06c" 9731 "00000☃"
  validate "06s" "☃" "00000☃"
  validate "^6c" 9731 "  ☃   "
  failure "^06c" 9731 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  // Here comes the see-no-evil monkey.
  validate "c" 128584 "🙈"
  validate "s" "🙈" "🙈"
  validate "-6c" 128584 "🙈     "
  validate "-6s" "🙈" "🙈     "
  failure "-06c" 128584 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
  validate "6c" 128584 "     🙈"
  validate "6s" "🙈" "     🙈"
  validate "06c" 128584 "00000🙈"
  validate "06s" "🙈" "00000🙈"
  validate "^6c" 128584 "  🙈   "
  validate "^6s" "🙈" "  🙈   "
  failure "^06c" 128584 "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT"
