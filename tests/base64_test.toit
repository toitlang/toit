// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import encoding.base64 as base64

main:
  expect_equals "" (base64.decode (base64.encode "")).to_string
  expect_equals "a" (base64.decode (base64.encode "a")).to_string
  expect_equals "ab" (base64.decode (base64.encode "ab")).to_string
  expect_equals "abc" (base64.decode (base64.encode "abc")).to_string
  expect_equals "abcd" (base64.decode (base64.encode "abcd")).to_string
  expect_equals "abcde" (base64.decode (base64.encode "abcde")).to_string
  expect_equals "abcdef" (base64.decode (base64.encode "abcdef")).to_string
  expect_equals "~~~" (base64.decode (base64.encode "~~~")).to_string
  expect_equals "~~~~" (base64.decode (base64.encode "~~~~")).to_string
  expect_equals "~~~~~" (base64.decode (base64.encode "~~~~~")).to_string

  expect_equals "" (base64.decode --url_mode (base64.encode "" --url_mode)).to_string
  expect_equals "a" (base64.decode --url_mode (base64.encode "a" --url_mode)).to_string
  expect_equals "ab" (base64.decode --url_mode (base64.encode "ab" --url_mode)).to_string
  expect_equals "abc" (base64.decode --url_mode (base64.encode "abc" --url_mode)).to_string
  expect_equals "abcd" (base64.decode --url_mode (base64.encode "abcd" --url_mode)).to_string
  expect_equals "abcde" (base64.decode --url_mode (base64.encode "abcde" --url_mode)).to_string
  expect_equals "abcdef" (base64.decode --url_mode (base64.encode "abcdef" --url_mode)).to_string
  expect_equals "~~~" (base64.decode --url_mode (base64.encode "~~~" --url_mode)).to_string
  expect_equals "~~~~" (base64.decode --url_mode (base64.encode "~~~~" --url_mode)).to_string
  expect_equals "~~~~~" (base64.decode --url_mode (base64.encode "~~~~~" --url_mode)).to_string

  ff_str ::= "~\u{ff}\u{ff}~"
  expect_equals ff_str (base64.decode (base64.encode ff_str)).to_string
  expect_equals ff_str (base64.decode --url_mode (base64.encode ff_str --url_mode)).to_string

  expect_equals
    "fn5+"
    base64.encode "~~~"
  expect_equals
    "fn5-"
    base64.encode "~~~" --url_mode
  expect_equals
    "fn5+fg=="
    base64.encode "~~~~"
  expect_equals
    "fn5-fg"
    base64.encode "~~~~" --url_mode
  expect_equals
    "fn5+fn4="
    base64.encode "~~~~~"
  expect_equals
    "fn5-fn4"
    base64.encode "~~~~~" --url_mode
  expect_equals
    "fsO/w79+"
    base64.encode ff_str
  expect_equals
    "fsO_w79-"
    base64.encode ff_str --url_mode

  expect_throw "OUT_OF_RANGE": base64.decode "fn5+f"      // Too short.
  expect_throw "OUT_OF_RANGE": base64.decode "fn5+f="     // Missing "=".
  expect_throw "OUT_OF_RANGE": base64.decode "fn5+f==="   // Too many "=".
  expect_throw "OUT_OF_RANGE": base64.decode "fn5+fn"     // Two missing "="s.
  expect_throw "OUT_OF_RANGE": base64.decode "fn5+fn="    // Missing "=".
  expect_throw "OUT_OF_RANGE": base64.decode "fn5+fn==="  // Extra "=".
  expect_throw "OUT_OF_RANGE": base64.decode "fn5+fn4"    // Missing "=".
  expect_throw "OUT_OF_RANGE": base64.decode "fn5+fn4=="  // Extra "=".
  expect_throw "OUT_OF_RANGE": base64.decode "fn5+fn4d="  // Lone "=".
  expect_throw "OUT_OF_RANGE": base64.decode "fn5+fn4d=="  // Two lone "="s.
  expect_throw "OUT_OF_RANGE": base64.decode "fn5+fn4d==="  // Three lone "="s.

  expect_throw "OUT_OF_RANGE": base64.decode "fn5-fn4=" --url_mode  // Superfluous "="
  expect_throw "OUT_OF_RANGE": base64.decode "fn5-fn==" --url_mode  // Superfluous "="
  expect_throw "OUT_OF_RANGE": base64.decode "fn5-f===" --url_mode  // Superfluous "="
  expect_throw "OUT_OF_RANGE": base64.decode "fn5-f"    --url_mode  // Impossible length.
