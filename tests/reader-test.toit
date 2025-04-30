// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import reader

class TestReader implements reader.Reader:
  index_ := 0
  arrays_ := ?

  constructor .arrays_:

  read:
    if index_ >= arrays_.size: return null
    return arrays_[index_++]

main:
  simple
  utf-8
  consumed

simple:
  r := reader.BufferedReader (TestReader ["H".to-byte-array, "ost: ".to-byte-array])  // NO-WARN
  expect-equals "Host" (r.peek-string 4)

  // Test read_until if delimiter exists
  r = reader.BufferedReader (TestReader ["H".to-byte-array, "ost: toitware.com".to-byte-array])  // NO-WARN
  expect-equals "Host" (r.read-until ':')
  expect-equals " toit" (r.peek-string 5)

  // TODO Test read_until if delimiter does not exist

DIFFICULT-STRING ::= "25€ and 23€¢ 🙈!"

utf-8:
  r := reader.BufferedReader (TestReader ["Sø".to-byte-array, "en så s".to-byte-array, "ær ud!".to-byte-array])  // NO-WARN
  expect (r.are-available 0)
  expect-not (r.are-available 1)  // Not yet read from the underlying TestReader.
  expect-equals "Sø" (r.read-string --max-size=3)
  expect-equals "en s" (r.read-string --max-size=5)
  expect (r.are-available 0)
  expect (r.are-available 4)
  expect-not (r.are-available 5)
  expect-throw "max_size was too small to read a single UTF-8 character": r.read-string --max-size=1
  expect-equals "å" (r.read-string --max-size=2)
  expect-equals " s" (r.read-string --max-size=3)
  expect-equals "ær ud!" r.read-string
  expect-equals null r.read-string

  r = reader.BufferedReader (TestReader ["Sø".to-byte-array, "en så s".to-byte-array, "ær ud!".to-byte-array])  // NO-WARN
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
  r := reader.BufferedReader (TestReader [ba[..split-point], ba[split-point..]])  // NO-WARN
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

class MultiByteArrayReader implements reader.Reader:
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

  read:
    return arrays[index++]

consumed:
  consumed-one-at-a-time
  consumed-get-and-unget
  consumed-thirteen-at-a-time

consumed-one-at-a-time:
  br := reader.BufferedReader MultiByteArrayReader  // NO-WARN
  256.repeat:
    expect-equals it br.consumed
    expect-equals it br.read-byte

consumed-get-and-unget:
  br2 := reader.BufferedReader MultiByteArrayReader  // NO-WARN
  expected-cursor := 0
  for i := 0; i < 256; i++:
    expect-equals expected-cursor i
    if i + 13 > 256: break
    br2.read-bytes 13
    expect-equals (expected-cursor + 13) br2.consumed
    br2.unget
        ByteArray 13
    expect-equals expected-cursor br2.consumed
    br2.read-byte
    expected-cursor++

consumed-thirteen-at-a-time:
  br3 := reader.BufferedReader MultiByteArrayReader  // NO-WARN
  for i := 0; i < 256; i += 13:
    expect-equals i br3.consumed
    br3.read-bytes 13
