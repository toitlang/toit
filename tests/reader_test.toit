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
  utf_8

simple:
  r := reader.BufferedReader (TestReader ["H".to_byte_array, "ost: ".to_byte_array])
  expect_equals "Host" (r.peek_string 4)

  // Test read_until if delimiter exists
  r = reader.BufferedReader (TestReader ["H".to_byte_array, "ost: toitware.com".to_byte_array])
  expect_equals "Host" (r.read_until ':')
  expect_equals " toit" (r.peek_string 5)

  // TODO Test read_until if delimiter does not exist

DIFFICULT_STRING ::= "25€ and 23€¢ 🙈!"

utf_8:
  r := reader.BufferedReader (TestReader ["Sø".to_byte_array, "en så s".to_byte_array, "ær ud!".to_byte_array])
  expect (r.are_available 0)
  expect_not (r.are_available 1)  // Not yet read from the underlying TestReader.
  expect_equals "Sø" (r.read_string --max_size=3)
  expect_equals "en s" (r.read_string --max_size=5)
  expect (r.are_available 0)
  expect (r.are_available 4)
  expect_not (r.are_available 5)
  expect_throw "max_size was too small to read a single UTF-8 character": r.read_string --max_size=1
  expect_equals "å" (r.read_string --max_size=2)
  expect_equals " s" (r.read_string --max_size=3)
  expect_equals "ær ud!" r.read_string
  expect_equals null r.read_string

  r = reader.BufferedReader (TestReader ["Sø".to_byte_array, "en så s".to_byte_array, "ær ud!".to_byte_array])
  expect_equals "Sø" r.read_string
  expect_equals "en så s" r.read_string
  expect_equals "ær ud!" r.read_string
  expect_equals null r.read_string

  // € is e2 82 ac
  S ::= DIFFICULT_STRING.to_byte_array
  for i := 1; i < S.size - 1; i++:
    for j := -4; j <= 4; j++:
      for k := 1; k < 5; k++:
        split_test S i j k

split_test ba/ByteArray split_point/int offset/int part_2_size:
  if split_point + offset <= 0: return
  if offset + split_point >= ba.size: return
  r := reader.BufferedReader (TestReader [ba[..split_point], ba[split_point..]])
  s1 := r.read_string --max_size=(split_point + offset)
  // Check we didn't get more bytes than we asked for unless we had to in
  // order to get a single multi-byte UTF-8 character.
  expect
    s1.size <= split_point + offset
  expect s1.size > 0
  s2 := ""
  exception := catch:
    s2 = r.read_string --max_size=part_2_size
  if exception:
    expect part_2_size < 4
    expect_equals "max_size was too small to read a single UTF-8 character" exception
  // Check we didn't get more bytes than we asked for.
  expect
    s2.size <= part_2_size
  expect s2.size >= 0
  while s1.size + s2.size < ba.size:
    s2 += r.read_string
  expect_equals null r.read_string
  expect_equals DIFFICULT_STRING
    s1 + s2
