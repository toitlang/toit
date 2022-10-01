// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import encoding.json
import fixed_point show FixedPoint
import math
import reader show Reader

main:
  test_parse
  test_stringify
  test_converter
  test_encode
  test_decode
  test_repeated_strings
  test_number_terminators
  test_with_reader

test_stringify:
  expect_equals "\"testing\"" (json.stringify "testing")
  expect_equals "\"€\"" (json.stringify "€")
  expect_equals "\"🙈\"" (json.stringify "🙈")
  expect_equals "\"\\\"\\\"\\\"\\\"\"" (json.stringify "\"\"\"\"")
  expect_equals "\"\\\\\\\"\"" (json.stringify "\\\"")
  expect_equals "\"\\u0000\"" (json.stringify "\x00")
  expect_equals "\"\\u0001\"" (json.stringify "\x01")

  expect_equals "5" (json.stringify 5)
  expect_equals "5.00" (json.stringify 5.0)
  expect_equals "0" (json.stringify 0)
  expect_equals "0.00" (json.stringify 0.0)
  expect_equals "-0.00" (json.stringify -0.00001)

  expect_equals "true" (json.stringify true)
  expect_equals "false" (json.stringify false)
  expect_equals "null" (json.stringify null)

  expect_equals "{}" (json.stringify {:})
  expect_equals """{"a":"b"}""" (json.stringify {"a":"b"})
  expect_equals """{"a":"b","c":"d"}""" (json.stringify {"a":"b","c":"d"})

  expect_equals "[]" (json.stringify [])
  expect_equals """["a"]""" (json.stringify ["a"])
  expect_equals """["a","b"]""" (json.stringify ["a","b"])

  expect_equals "\"\\\\ \\b \\f \\n \\r \\t\"" (json.stringify "\\ \b \f \n \r \t")

  expect_equals
    "\"" + "hej" * 1024 + "\""
    json.stringify "hej" * 1024

  HUGE := 14000
  very_large_string := "\x1b" * HUGE
  expect_equals HUGE very_large_string.size
  escaped := json.stringify very_large_string
  expect_equals (HUGE * 6 + 2) escaped.size
  expect
    escaped.starts_with "\"\\u001b\\u001b"
  expect
    escaped.ends_with     "\\u001b\\u001b\""

test_converter -> none:
  fixed_converter := : | obj encoder |
    if obj is FixedPoint:
      encoder.put_unquoted obj.stringify
      // Return null to indicate we have encoded the object we were passed and
      // nothing more needs to be done (in this case we didn't need this since
      // put_unquoted is none-typed and so implicitly returns null).
      null
    else:
      throw "INVALID_JSON_OBJECT"

  expect_equals "3.14" (json.stringify (FixedPoint math.PI --decimals=2) fixed_converter)
  expect_equals "3.142" (json.stringify (FixedPoint math.PI --decimals=3) fixed_converter)
  expect_equals "3.1416" (json.stringify (FixedPoint math.PI --decimals=4) fixed_converter)
  expect_equals "3.14159" (json.stringify (FixedPoint math.PI --decimals=5) fixed_converter)

  pi := FixedPoint math.PI
  e := FixedPoint math.E

  expect_equals "[3.14,2.72]" (json.stringify [pi, e] fixed_converter)

  time_converter := : | obj encoder |
    if obj is Time:
      encoder.encode obj.stringify
      // Return null to indicate we have encoded the object we were passed and
      // nothing more needs to be done.
      null
    else:
      throw "INVALID_JSON_OBJECT"

  stringify_converter := : | obj |
    obj.stringify  // Returns a string from the block, which is then encoded.

  erik := Time.from_string "1969-05-27T14:00:00Z"
  moon := Time.from_string "1969-07-20T20:17:00Z"

  expect_equals "[\"$erik\",\"$moon\"]" (json.stringify [erik, moon] time_converter)
  expect_equals "[\"$erik\",\"$moon\"]" (json.stringify [erik, moon] stringify_converter)

  fb1 := FooBar 1 2
  fb2 := FooBar "Tweedledum" "Tweedledee"

  to_json_converter := : | obj | obj.to_json  // Returns a short-lived object which is serialized.

  expect_equals
      """[{"foo":1,"bar":2},{"foo":"Tweedledum","bar":"Tweedledee"}]"""
      (json.stringify [fb1, fb2] to_json_converter)

  // Nested custom conversions.
  fb3 := FooBar fb1 fb2
  expect_equals
      """{"foo":{"foo":1,"bar":2},"bar":{"foo":"Tweedledum","bar":"Tweedledee"}}"""
      (json.stringify fb3 to_json_converter)

  // Using a lambda instead of a block.
  to_json_lambda := :: | obj | obj.to_json  // Returns a short-lived object which is serialized.
  expect_equals
      """{"foo":{"foo":1,"bar":2},"bar":{"foo":"Tweedledum","bar":"Tweedledee"}}"""
      (json.stringify fb3 to_json_lambda)

  byte_array_converter := : | obj encoder |
    encoder.put_list obj.size
      : | index | obj[index]    // Generator block returns integers.
      : unreachable             // Converter block will never be called since all elements are integers.

  expect_equals "[1,2,42,103]"
      json.stringify #[1, 2, 42, 103] byte_array_converter

class FooBar:
  foo := ?
  bar := ?

  constructor .foo .bar:

  to_json -> Map:
    return { "foo": foo, "bar": bar }

test_parse:
  expect_equals "testing" (json.parse "\"testing\"")
  expect_equals "€" (json.parse "\"€\"")
  expect_equals "🙈" (json.parse "\"🙈\"")  // We allow JSON that doesn't use surrogates.
  expect_equals "🙈" (json.parse "\"\\ud83d\\ude48\"")  // JSON can also use escaped surrogates.
  expect_equals "x🙈y" (json.parse "\"x\\ud83d\\ude48y\"")  // JSON can also use escaped surrogates.
  expect_equals "x€y" (json.parse "\"x\\u20aCy\"")
  expect_equals "\"\"\"\"" (json.parse "\"\\\"\\\"\\\"\\\"\"")
  expect_equals "\\\"" (json.parse "\"\\\\\\\"\"")

  expect_equals "testing" (json.parse "\n\t \"testing\"")

  expect_equals true (json.parse "true")
  expect_equals false (json.parse "false")
  expect_equals null (json.parse "null")

  expect_equals "\\ \b \f \n \r \t" (json.parse "\"\\\\ \\b \\f \\n \\r \\t\"")

  expect_equals "{}" (json.stringify (json.parse "{}"))
  expect_equals "{\"a\":\"b\"}" (json.stringify (json.parse "{\"a\":\"b\"}"))
  expect_equals "{\"a\":\"b\"}" (json.stringify (json.parse " { \"a\" : \"b\" } "))
  expect_equals "[\"a\",\"b\"]" (json.stringify (json.parse " [ \"a\" , \"b\" ] "))

  expect_equals "=\"\\/bfnrt"
      (json.parse "\"\\u003d\\u0022\\u005c\\u002F\\u0062\\u0066\\u006e\\u0072\\u0074\"")

  expect_throw "UNTERMINATED_JSON_STRING": json.parse"\"\\u"
  expect_throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud"
  expect_throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud8"
  expect_throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83"
  expect_throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d"
  expect_throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d\""
  expect_throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d\\"
  expect_throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d\\u"
  expect_throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d\\ud"
  expect_throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d\\ude"
  expect_throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d\\ude4"
  expect_throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d\\ude48"
  expect_equals "🙈" (json.parse"\"\\ud83d\\ude48\"")
  expect_throw "INVALID_SURROGATE_PAIR": json.parse"\"\\ud83d\\ud848\""

  json.parse UNICODE_EXAMPLE
  json.parse EXAMPLE

  json.decode UNICODE_EXAMPLE.to_byte_array
  json.decode EXAMPLE.to_byte_array

UNICODE_EXAMPLE ::= """
  {
    "x": "Æv bæv",
    "y": 123,
    "z": 3.14159,
    "æ": false,
    "ø": true,
    "å": null
  }
"""

EXAMPLE ::= """
  {
    "x": "Nyah nyah",
    "y": 123,
    "z": 3.14159,
    "a": false,
    "b": true,
    "c": null
  }
"""

test_encode:
  expect_equals "\"testing\"".to_byte_array (json.encode "testing")

test_decode:
  expect_equals "testing" (json.decode "\"testing\"".to_byte_array)

BIG ::= """
[
  {
    "foo": 1,
    "bar": 2,
    "baz": 3
  },
  {
    "foo": 3,
    "bar": 4,
    "baz": 5
  },
  {
    "foo": "fizz",
    "bar": "fizz",
    "baz": "fizz"
  }
]"""

NUMBER_WITH_LEADING_SPACE ::= " \r\n\t-123.54E-5"

// Numbers terminated by comma, space, tab, square bracket, curly brace, and
// newline.
NUMBER_ENDS_WITH ::= """
{ "foo": 123,
  "bar": 155 ,
  "baz": 103	,
  "fizz": [42, 3.1415],
  "bam": {"boom": 555},
  "bizz": 42\r,
  "buzz": 99
}
"""


test_repeated_strings:
  result := json.parse BIG
  check_big_parse_result result

check_big_parse_result result -> none:
  expect_equals 3 result.size
  expect_equals 1 result[0]["foo"]
  expect_equals 2 result[0]["bar"]
  expect_equals 3 result[0]["baz"]
  expect_equals "fizz" result[2]["foo"]
  expect_equals "fizz" result[2]["bar"]
  expect_equals "fizz" result[2]["baz"]

test_number_terminators:
  result := json.parse NUMBER_ENDS_WITH
  expect_equals 123 result["foo"]
  expect_equals 155 result["bar"]
  expect_equals 103 result["baz"]
  expect_equals 42 result["fizz"][0]
  expect_equals 3.1415 result["fizz"][1]
  expect_equals 555 result["bam"]["boom"]
  expect_equals 99 result["buzz"]

  expect_throw "FLOAT_PARSING_ERROR": json.parse "[3.1E]"

  expect_throw "FLOAT_PARSING_ERROR": json.parse "[3.1M]"

  expect_throw "INVALID_JSON_CHARACTER": json.parse "[3.1\x01]"

  // Because of the way the JSON parser works, it's a bit random
  // what error you get in the rare case when the JSON is invalid.
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1!"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1#"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1%"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1&"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1/"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1("
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1)"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1="
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1-"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1_"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1?"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1*"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1'"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1ß"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1ö"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1ü"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1ä"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1ÿ"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1ë"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1ï"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1æ"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1ø"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1å"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1è"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1é"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1µ"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1ł"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1€"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1a"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1b"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1c"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1d"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1e"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1f"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1g"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1h"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1i"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1j"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1k"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1l"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1m"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1n"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1o"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1p"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1q"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1r"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1r"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1s"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1t"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1u"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1v"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1w"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1x"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1y"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "3.1z"
  expect_throw_parse_number "FLOAT_PARSING_ERROR"    "3.1.f"
  expect_throw_parse_number "INVALID_JSON_CHARACTER" "31.f"

expect_throw_parse_number error/string str/string -> none:
  expect_throw error: json.parse str
  expect_throw error: json.parse " $str "
  expect_throw error: json.parse "[$str]"
  expect_throw error: json.parse "[ $str ]"
  expect_throw error: json.parse "{\"foo\":$str]"
  expect_throw error: json.parse "{\"foo\": $str ]"

class TestReader implements Reader:
  pos := 0
  list := ?
  throw_on_last_part := false

  constructor .list:
    list.size.repeat:
      if list[it] is not ByteArray:
        list[it] = list[it].to_byte_array

  read:
    if pos == list.size: return null
    if throw_on_last_part and pos == list.size - 1:
      throw "READ_ERROR"
    return list[pos++]

test_with_reader:
  expect_equals 3.1415
    json.decode_stream
      TestReader ["3", ".", "1", "4", "1", "5"]

  // Split in middle of number in list.
  result := json.decode_stream
    TestReader ["[3, 5, 4", "2, 103]"]
  expect_equals 4 result.size
  expect_equals 3 result[0]
  expect_equals 5 result[1]
  expect_equals 42 result[2]
  expect_equals 103 result[3]

  // Split in middle of number in map.
  result = json.decode_stream
    TestReader [""" {"foo": 3, "bar": 5, "baz": 4""", """2, "fizz": 103}"""]
  expect_equals 4 result.size
  expect_equals 3 result["foo"]
  expect_equals 5 result["bar"]
  expect_equals 42 result["baz"]
  expect_equals 103 result["fizz"]

  // Split anywhere:
  BIG.size.repeat:
    part_1 := BIG[..it]
    part_2 := BIG[it..]
    result = json.decode_stream
      TestReader [part_1, part_2]
    check_big_parse_result result
    part_2.size.repeat:
      part_2a := part_2[..it]
      part_2b := part_2[it..]
      result = json.decode_stream
        TestReader [part_1, part_2a, part_2b]
      check_big_parse_result result

  // Exceptions from the reader should not be swallowed by the
  // streaming JSON decoder.
  BIG.size.repeat:
    part_1 := BIG[..it]
    part_2 := BIG[it..]
    test_reader := TestReader [part_1, part_2]
    test_reader.throw_on_last_part = true
    expect_throw "READ_ERROR":
      json.decode_stream test_reader

  // Split anywhere:
  NUMBER_WITH_LEADING_SPACE.size.repeat:
    part_1 := NUMBER_WITH_LEADING_SPACE[..it]
    part_2 := NUMBER_WITH_LEADING_SPACE[it..]
    result = json.decode_stream
      TestReader [part_1, part_2]
    expect_equals -123.54e-5 result
