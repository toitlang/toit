// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import encoding.maskint show *
import encoding.maskint
import encoding.url

main:
  maskint_test
  url_test
  url_decoding_test

maskint_test:
  0x100.repeat:
    expect_equals
      MASKINT_RESULT[it]
      maskint.byte_size --offset=it ALL

ALL := ByteArray 0x100: it

MASKINT_RESULT ::= #[
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
  4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
  5, 5, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 8, 9,
]

url_test:
  expect_equals "foo" (url.encode "foo")
  expect_equals "-_.~abcABC012" (url.encode "-_.~abcABC012")
  expect_equals "%20" (url.encode " ").to_string
  expect_equals "%25" (url.encode "%").to_string
  expect_equals "%2B" (url.encode "+").to_string
  expect_equals "%00%01%02%03%04" (url.encode (ByteArray 5: it)).to_string
  expect_equals "%F0%F1%F2%F3%F4" (url.encode (ByteArray 5: 0xf0 + it)).to_string
  expect_equals "%F1sh" (url.encode #[0xf1, 's', 'h']).to_string
  expect_equals "-%E2%98%83-" (url.encode "-☃-").to_string
  expect_equals "%E2%82%AC25%2C-" (url.encode "€25,-").to_string

url_decoding_test:
  expect_equals "foo" (url.decode "foo")
  expect_equals "-_.~abcABC012" (url.decode "-_.~abcABC012")
  expect_equals "Søen så sær ud" (url.decode "Søen så sær ud")  // Postel.
  expect_equals " " (url.decode "%20").to_string
  expect_equals "%" (url.decode "%25").to_string
  expect_equals "+" (url.decode "+")            // Doesn't treat '+' specially.
  expect_equals "+" (url.decode "%2B").to_string
  expect_equals #[0, 1, 2, 3, 4] (url.decode (ByteArray 5: it))
  expect_equals #[0, 1, 2, 3, 4] (url.decode "%00%01%02%03%04")
  expect_equals #[0xf0, 0xf1, 0xf2] (url.decode (ByteArray 3: 0xf0 + it))
  expect_equals #[0xf0, 0xf1, 0xf2] (url.decode "%F0%F1%F2")
  expect_equals #[0xf0, 0xf1, 0xf2] (url.decode "%f0%f1%f2")  // Lower case.
  expect_equals "%F1sh" (url.encode #[0xf1, 's', 'h']).to_string
  expect_equals "-☃-" (url.decode "-%E2%98%83-").to_string
  expect_equals "€25,-" (url.decode "%E2%82%AC25%2C-").to_string

