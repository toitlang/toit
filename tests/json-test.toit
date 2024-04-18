// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import encoding.json
import fixed-point show FixedPoint
import math
import reader show Reader BufferedReader
import io

main:
  test-parse
  test-stringify
  test-converter
  test-encode
  test-decode
  test-repeated-strings
  test-number-terminators
  test-with-reader
  test-multiple-objects
  test-stream

test-stringify:
  expect-equals "\"testing\"" (json.stringify "testing")
  expect-equals "\"€\"" (json.stringify "€")
  expect-equals "\"🙈\"" (json.stringify "🙈")
  expect-equals "\"\\\"\\\"\\\"\\\"\"" (json.stringify "\"\"\"\"")
  expect-equals "\"\\\\\\\"\"" (json.stringify "\\\"")
  expect-equals "\"\\u0000\"" (json.stringify "\x00")
  expect-equals "\"\\u0001\"" (json.stringify "\x01")

  expect-equals "5" (json.stringify 5)
  expect-equals "5.00" (json.stringify 5.0)
  expect-equals "0" (json.stringify 0)
  expect-equals "0.00" (json.stringify 0.0)
  expect-equals "-0.00" (json.stringify -0.00001)

  expect-equals "true" (json.stringify true)
  expect-equals "false" (json.stringify false)
  expect-equals "null" (json.stringify null)

  expect-equals "{}" (json.stringify {:})
  expect-equals """{"a":"b"}""" (json.stringify {"a":"b"})
  expect-equals """{"a":"b","c":"d"}""" (json.stringify {"a":"b","c":"d"})

  expect-equals "[]" (json.stringify [])
  expect-equals """["a"]""" (json.stringify ["a"])
  expect-equals """["a","b"]""" (json.stringify ["a","b"])

  expect-equals "\"\\\\ \\b \\f \\n \\r \\t\"" (json.stringify "\\ \b \f \n \r \t")

  expect-equals
    "\"" + "hej" * 1024 + "\""
    json.stringify "hej" * 1024

  HUGE := 14000
  very-large-string := "\x1b" * HUGE
  expect-equals HUGE very-large-string.size
  escaped := json.stringify very-large-string
  expect-equals (HUGE * 6 + 2) escaped.size
  expect
    escaped.starts-with "\"\\u001b\\u001b"
  expect
    escaped.ends-with     "\\u001b\\u001b\""

test-converter -> none:
  fixed-converter := : | obj encoder |
    if obj is FixedPoint:
      encoder.put-unquoted obj.stringify
      // Return null to indicate we have encoded the object we were passed and
      // nothing more needs to be done (in this case we didn't need this since
      // put_unquoted is none-typed and so implicitly returns null).
      null
    else:
      throw "INVALID_JSON_OBJECT"

  expect-equals "3.14" (json.stringify (FixedPoint math.PI --decimals=2) fixed-converter)
  expect-equals "3.142" (json.stringify (FixedPoint math.PI --decimals=3) fixed-converter)
  expect-equals "3.1416" (json.stringify (FixedPoint math.PI --decimals=4) fixed-converter)
  expect-equals "3.14159" (json.stringify (FixedPoint math.PI --decimals=5) fixed-converter)

  pi := FixedPoint math.PI
  e := FixedPoint math.E

  expect-equals "[3.14,2.72]" (json.stringify [pi, e] fixed-converter)

  time-converter := : | obj encoder |
    if obj is Time:
      encoder.encode obj.stringify
      // Return null to indicate we have encoded the object we were passed and
      // nothing more needs to be done.
      null
    else:
      throw "INVALID_JSON_OBJECT"

  stringify-converter := : | obj |
    obj.stringify  // Returns a string from the block, which is then encoded.

  erik := Time.parse "1969-05-27T14:00:00Z"
  moon := Time.parse "1969-07-20T20:17:00Z"

  expect-equals "[\"$erik\",\"$moon\"]" (json.stringify [erik, moon] time-converter)
  expect-equals "[\"$erik\",\"$moon\"]" (json.stringify [erik, moon] stringify-converter)

  fb1 := FooBar 1 2
  fb2 := FooBar "Tweedledum" "Tweedledee"

  to-json-converter := : | obj | obj.to-json  // Returns a short-lived object which is serialized.

  expect-equals
      """[{"foo":1,"bar":2},{"foo":"Tweedledum","bar":"Tweedledee"}]"""
      (json.stringify [fb1, fb2] to-json-converter)

  // Nested custom conversions.
  fb3 := FooBar fb1 fb2
  expect-equals
      """{"foo":{"foo":1,"bar":2},"bar":{"foo":"Tweedledum","bar":"Tweedledee"}}"""
      (json.stringify fb3 to-json-converter)

  // Using a lambda instead of a block.
  to-json-lambda := :: | obj | obj.to-json  // Returns a short-lived object which is serialized.
  expect-equals
      """{"foo":{"foo":1,"bar":2},"bar":{"foo":"Tweedledum","bar":"Tweedledee"}}"""
      (json.stringify fb3 to-json-lambda)

  byte-array-converter := : | obj encoder |
    encoder.put-list obj.size
      : | index | obj[index]    // Generator block returns integers.
      : unreachable             // Converter block will never be called since all elements are integers.

  expect-equals "[1,2,42,103]"
      json.stringify #[1, 2, 42, 103] byte-array-converter

class FooBar:
  foo := ?
  bar := ?

  constructor .foo .bar:

  to-json -> Map:
    return { "foo": foo, "bar": bar }

test-parse:
  expect-equals "testing" (json.parse "\"testing\"")
  expect-equals "€" (json.parse "\"€\"")
  expect-equals "🙈" (json.parse "\"🙈\"")  // We allow JSON that doesn't use surrogates.
  expect-equals "🙈" (json.parse "\"\\ud83d\\ude48\"")  // JSON can also use escaped surrogates.
  expect-equals "x🙈y" (json.parse "\"x\\ud83d\\ude48y\"")  // JSON can also use escaped surrogates.
  expect-equals "x€y" (json.parse "\"x\\u20aCy\"")
  expect-equals "\"\"\"\"" (json.parse "\"\\\"\\\"\\\"\\\"\"")
  expect-equals "\\\"" (json.parse "\"\\\\\\\"\"")

  expect-equals "testing" (json.parse "\n\t \"testing\"")

  expect-equals true (json.parse "true")
  expect-equals false (json.parse "false")
  expect-equals null (json.parse "null")

  expect-equals "\\ \b \f \n \r \t" (json.parse "\"\\\\ \\b \\f \\n \\r \\t\"")

  expect-equals "{}" (json.stringify (json.parse "{}"))
  expect-equals "{\"a\":\"b\"}" (json.stringify (json.parse "{\"a\":\"b\"}"))
  expect-equals "{\"a\":\"b\"}" (json.stringify (json.parse " { \"a\" : \"b\" } "))
  expect-equals "[\"a\",\"b\"]" (json.stringify (json.parse " [ \"a\" , \"b\" ] "))

  expect-equals "=\"\\/bfnrt"
      (json.parse "\"\\u003d\\u0022\\u005c\\u002F\\u0062\\u0066\\u006e\\u0072\\u0074\"")

  expect-throw "UNTERMINATED_JSON_STRING": json.parse"\"\\u"
  expect-throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud"
  expect-throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud8"
  expect-throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83"
  expect-throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d"
  expect-throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d\""
  expect-throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d\\"
  expect-throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d\\u"
  expect-throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d\\ud"
  expect-throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d\\ude"
  expect-throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d\\ude4"
  expect-throw "UNTERMINATED_JSON_STRING": json.parse"\"\\ud83d\\ude48"
  expect-equals "🙈" (json.parse"\"\\ud83d\\ude48\"")
  expect-throw "INVALID_SURROGATE_PAIR": json.parse"\"\\ud83d\\ud848\""

  json.parse UNICODE-EXAMPLE
  json.parse EXAMPLE

  json.decode UNICODE-EXAMPLE.to-byte-array
  json.decode EXAMPLE.to-byte-array

UNICODE-EXAMPLE ::= """
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

test-encode:
  expect-equals "\"testing\"".to-byte-array (json.encode "testing")

test-decode:
  expect-equals "testing" (json.decode "\"testing\"".to-byte-array)

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

NUMBER-WITH-LEADING-SPACE ::= " \r\n\t-123.54E-5"

// Numbers terminated by comma, space, tab, square bracket, curly brace, and
// newline.
NUMBER-ENDS-WITH ::= """
{ "foo": 123,
  "bar": 155 ,
  "baz": 103	,
  "fizz": [42, 3.1415],
  "bam": {"boom": 555},
  "bizz": 42\r,
  "buzz": 99
}
"""


test-repeated-strings:
  result := json.parse BIG
  check-big-parse-result result

check-big-parse-result result -> none:
  expect-equals 3 result.size
  expect-equals 1 result[0]["foo"]
  expect-equals 2 result[0]["bar"]
  expect-equals 3 result[0]["baz"]
  expect-equals "fizz" result[2]["foo"]
  expect-equals "fizz" result[2]["bar"]
  expect-equals "fizz" result[2]["baz"]

test-number-terminators:
  result := json.parse NUMBER-ENDS-WITH
  expect-equals 123 result["foo"]
  expect-equals 155 result["bar"]
  expect-equals 103 result["baz"]
  expect-equals 42 result["fizz"][0]
  expect-equals 3.1415 result["fizz"][1]
  expect-equals 555 result["bam"]["boom"]
  expect-equals 99 result["buzz"]

  expect-throw "FLOAT_PARSING_ERROR": json.parse "[3.1E]"

  expect-throw "FLOAT_PARSING_ERROR": json.parse "[3.1M]"

  expect-throw "INVALID_JSON_CHARACTER": json.parse "[3.1\x01]"

  // Because of the way the JSON parser works, it's a bit random
  // what error you get in the rare case when the JSON is invalid.
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1!"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1#"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1%"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1&"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1/"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1("
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1)"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1="
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1-"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1_"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1?"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1*"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1'"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1ß"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1ö"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1ü"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1ä"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1ÿ"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1ë"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1ï"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1æ"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1ø"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1å"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1è"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1é"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1µ"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1ł"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1€"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1a"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1b"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1c"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1d"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1e"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1f"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1g"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1h"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1i"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1j"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1k"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1l"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1m"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1n"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1o"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1p"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1q"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1r"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1r"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1s"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1t"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1u"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1v"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1w"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1x"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1y"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "3.1z"
  expect-throw-parse-number "FLOAT_PARSING_ERROR"    "3.1.f"
  expect-throw-parse-number "INVALID_JSON_CHARACTER" "31.f"

expect-throw-parse-number error/string str/string -> none:
  expect-throw error: json.parse str
  expect-throw error: json.parse " $str "
  expect-throw error: json.parse "[$str]"
  expect-throw error: json.parse "[ $str ]"
  expect-throw error: json.parse "{\"foo\":$str]"
  expect-throw error: json.parse "{\"foo\": $str ]"

class TestReader implements Reader:
  pos := 0
  list := ?
  throw-on-last-part := false

  constructor .list:
    list.size.repeat:
      if list[it] is not ByteArray:
        list[it] = list[it].to-byte-array

  read:
    if pos == list.size: return null
    if throw-on-last-part and pos == list.size - 1:
      throw "READ_ERROR"
    return list[pos++]

class TestIoReader extends TestReader with io.InMixin:
  constructor list:
    super list

  read_ -> ByteArray?:
    return read

io-reader-for list -> io.Reader:
  return (TestIoReader list).in

test-multiple-objects -> none:
  VECTORS ::= [
      // Put the border between the reads in different places.
      [ """{"foo": 42}""", """{"bar": 103}"""],
      [ """{"foo": 42}{"ba""", """r": 103}"""],
      [ """{"foo": 4""", """2}{"bar": 103}"""],
  ]
  VECTORS.do:
    buffered := BufferedReader (TestReader it)
    first := json.decode-stream buffered
    second := json.decode-stream buffered
    expect-equals 42 first["foo"]
    expect-equals 103 second["bar"]

    reader := io-reader-for it
    first = json.decode-stream reader
    second = json.decode-stream reader
    expect-equals 42 first["foo"]
    expect-equals 103 second["bar"]

test-with-reader -> none:
  expect-equals 3.1415
      json.decode-stream
          io-reader-for ["3", ".", "1", "4", "1", "5"]

  // Split in middle of number in list.
  result := json.decode-stream
      io-reader-for ["[3, 5, 4", "2, 103]"]
  expect-equals 4 result.size
  expect-equals 3 result[0]
  expect-equals 5 result[1]
  expect-equals 42 result[2]
  expect-equals 103 result[3]

  // Split in middle of number in map.
  result = json.decode-stream
      io-reader-for [""" {"foo": 3, "bar": 5, "baz": 4""", """2, "fizz": 103}"""]
  expect-equals 4 result.size
  expect-equals 3 result["foo"]
  expect-equals 5 result["bar"]
  expect-equals 42 result["baz"]
  expect-equals 103 result["fizz"]

  // Split anywhere:
  BIG.size.repeat:
    part-1 := BIG[..it]
    part-2 := BIG[it..]
    result = json.decode-stream
        io-reader-for [part-1, part-2]
    check-big-parse-result result
    part-2.size.repeat:
      part-2a := part-2[..it]
      part-2b := part-2[it..]
      result = json.decode-stream
          io-reader-for [part-1, part-2a, part-2b]
      check-big-parse-result result

  // Exceptions from the reader should not be swallowed by the
  // streaming JSON decoder.
  BIG.size.repeat:
    part-1 := BIG[..it]
    part-2 := BIG[it..]
    test-reader := TestIoReader [part-1, part-2]
    test-reader.throw-on-last-part = true
    expect-throw "READ_ERROR":
      json.decode-stream test-reader.in

  BAD-JSON-EXAMPLES ::= [
    """{"foo": 3 "bar": 4}""",
    """{"x":[{"foo": 3 "bar": 4}]}""",
    """{"a":{"b":{"c":[]},"de":{"e":"f" "g":[]}}}""",
  ]
  BAD-JSON-EXAMPLES.do: | example |
    example.size.repeat:
      part-1 := example[..it]
      part-2 := example[it..]
      expect-throw "INVALID_JSON_CHARACTER":
        json.decode-stream (io-reader-for [part-1, part-2])

    example-bytes := example.to-byte-array
    chunks := []
    example-bytes.size.repeat:
      chunks.add example-bytes[it .. it + 1]

    expect-throw "INVALID_JSON_CHARACTER":
      json.decode-stream (io-reader-for chunks)

  // Split anywhere:
  NUMBER-WITH-LEADING-SPACE.size.repeat:
    part-1 := NUMBER-WITH-LEADING-SPACE[..it]
    part-2 := NUMBER-WITH-LEADING-SPACE[it..]
    result = json.decode-stream
        io-reader-for [part-1, part-2]
    expect-equals -123.54e-5 result

test-stream:
  OBJ ::= {"foo": 42}

  writer := TestWriter
  json.encode-stream --writer=writer OBJ

  encoded := json.encode OBJ

  expect-equals ("{\"foo\":42}".to-byte-array) encoded
  expect-equals writer.ba encoded

class TestWriter extends io.Writer:
  ba := #[]
  try-write_ data from/int to/int -> int:
    slice := data[from..to]
    if slice is string:
      ba += slice.to-byte-array
    else:
      ba += slice
    return to - from
