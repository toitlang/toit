// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import encoding.base64 as base64

import .io-utils

main:
  expect-equals "" (base64.decode (base64.encode "")).to-string
  expect-equals "a" (base64.decode (base64.encode "a")).to-string
  expect-equals "ab" (base64.decode (base64.encode "ab")).to-string
  expect-equals "abc" (base64.decode (base64.encode "abc")).to-string
  expect-equals "abcd" (base64.decode (base64.encode "abcd")).to-string
  expect-equals "abcde" (base64.decode (base64.encode "abcde")).to-string
  expect-equals "abcdef" (base64.decode (base64.encode "abcdef")).to-string
  expect-equals "~~~" (base64.decode (base64.encode "~~~")).to-string
  expect-equals "~~~~" (base64.decode (base64.encode "~~~~")).to-string
  expect-equals "~~~~~" (base64.decode (base64.encode "~~~~~")).to-string

  expect-equals "fn5+fn4=" (base64.encode (FakeData "~~~~~"))
  expect-equals "fn5-fn4" (base64.encode --url-mode (FakeData "~~~~~"))

  expect-equals "~~~~~" (base64.decode (FakeData "fn5+fn4=")).to-string
  expect-equals "~~~~~" (base64.decode --url-mode (FakeData "fn5-fn4")).to-string

  expect-equals "" (base64.decode --url-mode (base64.encode "" --url-mode)).to-string
  expect-equals "a" (base64.decode --url-mode (base64.encode "a" --url-mode)).to-string
  expect-equals "ab" (base64.decode --url-mode (base64.encode "ab" --url-mode)).to-string
  expect-equals "abc" (base64.decode --url-mode (base64.encode "abc" --url-mode)).to-string
  expect-equals "abcd" (base64.decode --url-mode (base64.encode "abcd" --url-mode)).to-string
  expect-equals "abcde" (base64.decode --url-mode (base64.encode "abcde" --url-mode)).to-string
  expect-equals "abcdef" (base64.decode --url-mode (base64.encode "abcdef" --url-mode)).to-string
  expect-equals "~~~" (base64.decode --url-mode (base64.encode "~~~" --url-mode)).to-string
  expect-equals "~~~~" (base64.decode --url-mode (base64.encode "~~~~" --url-mode)).to-string
  expect-equals "~~~~~" (base64.decode --url-mode (base64.encode "~~~~~" --url-mode)).to-string

  ff-str ::= "~\u{ff}\u{ff}~"
  expect-equals ff-str (base64.decode (base64.encode ff-str)).to-string
  expect-equals ff-str (base64.decode --url-mode (base64.encode ff-str --url-mode)).to-string

  expect-equals
    "fn5+"
    base64.encode "~~~"
  expect-equals
    "fn5-"
    base64.encode "~~~" --url-mode
  expect-equals
    "fn5+fg=="
    base64.encode "~~~~"
  expect-equals
    "fn5-fg"
    base64.encode "~~~~" --url-mode
  expect-equals
    "fn5+fn4="
    base64.encode "~~~~~"
  expect-equals
    "fn5-fn4"
    base64.encode "~~~~~" --url-mode
  expect-equals
    "fsO/w79+"
    base64.encode ff-str
  expect-equals
    "fsO_w79-"
    base64.encode ff-str --url-mode

  expect-throw "OUT_OF_RANGE": base64.decode "fn5+f"      // Too short.
  expect-throw "OUT_OF_RANGE": base64.decode "fn5+f="     // Missing "=".
  expect-throw "OUT_OF_RANGE": base64.decode "fn5+f==="   // Too many "=".
  expect-throw "OUT_OF_RANGE": base64.decode "fn5+fn"     // Two missing "="s.
  expect-throw "OUT_OF_RANGE": base64.decode "fn5+fn="    // Missing "=".
  expect-throw "OUT_OF_RANGE": base64.decode "fn5+fn==="  // Extra "=".
  expect-throw "OUT_OF_RANGE": base64.decode "fn5+fn4"    // Missing "=".
  expect-throw "OUT_OF_RANGE": base64.decode "fn5+fn4=="  // Extra "=".
  expect-throw "OUT_OF_RANGE": base64.decode "fn5+fn4d="  // Lone "=".
  expect-throw "OUT_OF_RANGE": base64.decode "fn5+fn4d=="  // Two lone "="s.
  expect-throw "OUT_OF_RANGE": base64.decode "fn5+fn4d==="  // Three lone "="s.

  expect-throw "OUT_OF_RANGE": base64.decode "fn5-fn4=" --url-mode  // Superfluous "="
  expect-throw "OUT_OF_RANGE": base64.decode "fn5-fn==" --url-mode  // Superfluous "="
  expect-throw "OUT_OF_RANGE": base64.decode "fn5-f===" --url-mode  // Superfluous "="
  expect-throw "OUT_OF_RANGE": base64.decode "fn5-f"    --url-mode  // Impossible length.
