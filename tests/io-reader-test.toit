// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import .io-utils

main:
  simple
  utf-8
  processed

simple:
  r := TestReader ["H".to-byte-array, "ost: ".to-byte-array]
  expect-equals "Host" (r.peek-string 4)

  // Test read_until if delimiter exists
  r = TestReader ["H".to-byte-array, "ost: toitware.com".to-byte-array]
  expect-equals "Host" (r.read-string-up-to ':')
  expect-equals " toit" (r.peek-string 5)

  // TODO Test read_until if delimiter does not exist

DIFFICULT-STRING ::= "25€ and 23€¢ 🙈!"

utf-8:
  r := TestReader ["Sø".to-byte-array, "en så s".to-byte-array, "ær ud!".to-byte-array]
  expect (r.is-buffered 0)
  expect-not (r.is-buffered 1)  // Not yet read from the underlying TestReader.
  expect-equals "Sø" (r.read-string --max-size=3)
  expect-equals "en s" (r.read-string --max-size=5)
  expect (r.is-buffered 0)
  expect (r.is-buffered 4)
  expect-not (r.is-buffered 5)
  expect-throw "max_size was too small to read a single UTF-8 character": r.read-string --max-size=1
  expect-equals "å" (r.read-string --max-size=2)
  expect-equals " s" (r.read-string --max-size=3)
  expect-equals "ær ud!" r.read-string
  expect-equals null r.read-string

  r = TestReader ["Sø".to-byte-array, "en så s".to-byte-array, "ær ud!".to-byte-array]
  expect-equals "Sø" r.read-string
  expect-equals "en så s" r.read-string
  expect-equals "ær ud!" r.read-string
  expect-equals null r.read-string

  // € is e2 82 ac
  S ::= DIFFICULT-STRING.to-byte-array
  for i := 1; i < S.size - 1; i++:
    for j := -4; j <= 4; j++:
      for k := 1; k < 5; k++:
        split-test S i j k

split-test ba/ByteArray split-point/int offset/int part-2-size:
  if split-point + offset <= 0: return
  if offset + split-point >= ba.size: return
  r := TestReader [ba[..split-point], ba[split-point..]]
  s1 := r.read-string --max-size=(split-point + offset)
  // Check we didn't get more bytes than we asked for unless we had to in
  // order to get a single multi-byte UTF-8 character.
  expect
    s1.size <= split-point + offset
  expect s1.size > 0
  s2 := ""
  exception := catch:
    s2 = r.read-string --max-size=part-2-size
  if exception:
    expect part-2-size < 4
    expect-equals "max_size was too small to read a single UTF-8 character" exception
  // Check we didn't get more bytes than we asked for.
  expect
    s2.size <= part-2-size
  expect s2.size >= 0
  while s1.size + s2.size < ba.size:
    s2 += r.read-string
  expect-equals null r.read-string
  expect-equals DIFFICULT-STRING
    s1 + s2

class MultiByteArrayReader extends io.Reader:
  arrays /List ::= []
  index /int := 0

  constructor:
    arrays.add
        ByteArray 13: it
    arrays.add
        ByteArray 1: it + 13
    arrays.add
        ByteArray 5: it + 14
    arrays.add
        ByteArray 95: it + 19
    arrays.add
        ByteArray 12: it + 114
    arrays.add
        ByteArray 42: it + 126
    arrays.add
        ByteArray 2: it + 168
    arrays.add
        ByteArray 29: it + 170
    arrays.add
        ByteArray 45: it + 199
    arrays.add
        ByteArray 45: it + 244
    arrays.add
        ByteArray 10: it + 254
    arrays.add
        ByteArray 1: it + 255

  read_:
    return arrays[index++]

  close_:

processed:
  processed-one-at-a-time
  processed-get-and-unget
  processed-thirteen-at-a-time

processed-one-at-a-time:
  br := MultiByteArrayReader
  256.repeat:
    expect-equals it br.processed
    expect-equals it br.read-byte

processed-get-and-unget:
  br2 := MultiByteArrayReader
  expected-cursor := 0
  for i := 0; i < 256; i++:
    expect-equals expected-cursor i
    if i + 13 > 256: break
    br2.read-bytes 13
    expect-equals (expected-cursor + 13) br2.processed
    br2.unget
        ByteArray 13
    expect-equals expected-cursor br2.processed
    br2.read-byte
    expected-cursor++

processed-thirteen-at-a-time:
  br3 := MultiByteArrayReader
  for i := 0; i < 256; i += 13:
    expect-equals i br3.processed
    br3.read-bytes 13
