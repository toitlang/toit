// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import encoding.yaml
import fixed_point show FixedPoint
import math
import reader show Reader BufferedReader

main:
  test-stringify
  test-converter
  test-encode
  test-parse
  test-decode
  test-repeated-strings
  test-number-terminators

test-stringify:
  expect-equals "testing" (yaml.stringify "testing")
  expect-equals "€" (yaml.stringify "€")
  expect-equals "🙈" (yaml.stringify "🙈")
  expect-equals "\"\\\"\\\"\\\"\\\"\"" (yaml.stringify "\"\"\"\"")
  expect-equals "\"\\\\\\\"\"" (yaml.stringify "\\\"")
  expect-equals "\"\\u0000\"" (yaml.stringify "\x00")
  expect-equals "\"\\u0001\"" (yaml.stringify "\x01")

  expect-equals "\"a: \"" (yaml.stringify "a: ")
  expect-equals "\": a\"" (yaml.stringify ": a")
  expect-equals "\"a- \"" (yaml.stringify "a- ")
  expect-equals "\"- a\"" (yaml.stringify "- a")
  expect-equals "\"a& \"" (yaml.stringify "a& ")
  expect-equals "\"& a\"" (yaml.stringify "& a")
  expect-equals "\"a: \"" (yaml.stringify "a: ")
  expect-equals "\" [a\"" (yaml.stringify " [a")
  expect-equals "\"[a\"" (yaml.stringify "[a")
  expect-equals "\" {a\"" (yaml.stringify " {a")
  expect-equals "\"{a\"" (yaml.stringify "{a")


  expect-equals "5" (yaml.stringify 5)
  expect-equals "5.00" (yaml.stringify 5.0)
  expect-equals "0" (yaml.stringify 0)
  expect-equals "0.00" (yaml.stringify 0.0)
  expect-equals "-0.00" (yaml.stringify -0.00001)

  expect-equals "true" (yaml.stringify true)
  expect-equals "false" (yaml.stringify false)
  expect-equals "" (yaml.stringify null)

  expect-equals "{}" (yaml.stringify {:})
  expect-equals """a: b\n""" (yaml.stringify {"a":"b"})
  expect-equals """a: b\nc: d\n""" (yaml.stringify {"a":"b","c":"d"})

  expect-equals "[]" (yaml.stringify [])
  expect-equals """- a\n""" (yaml.stringify ["a"])
  expect-equals """- a\n- b\n""" (yaml.stringify ["a","b"])

  expect-equals "\"\\\\ \\b \\f \\n \\r \\t\"" (yaml.stringify "\\ \b \f \n \r \t")

  expect-equals
    "hej" * 1024
    yaml.stringify "hej" * 1024

  HUGE := 14000
  very-large-string := "\x1b" * HUGE
  expect-equals HUGE very-large-string.size
  escaped := yaml.stringify very-large-string
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
      throw "INVALID_YAML_OBJECT"

  expect-equals "3.14" (yaml.stringify (FixedPoint math.PI --decimals=2) fixed-converter)
  expect-equals "3.142" (yaml.stringify (FixedPoint math.PI --decimals=3) fixed-converter)
  expect-equals "3.1416" (yaml.stringify (FixedPoint math.PI --decimals=4) fixed-converter)
  expect-equals "3.14159" (yaml.stringify (FixedPoint math.PI --decimals=5) fixed-converter)

  pi := FixedPoint math.PI
  e := FixedPoint math.E

  expect-equals "- 3.14\n- 2.72\n" (yaml.stringify [pi, e] fixed-converter)

  time-converter := : | obj encoder |
    if obj is Time:
      encoder.encode obj.stringify
      // Return null to indicate we have encoded the object we were passed and
      // nothing more needs to be done.
      null
    else:
      throw "INVALID_YAML_OBJECT"

  stringify-converter := : | obj |
    obj.stringify  // Returns a string from the block, which is then encoded.

  erik := Time.parse "1969-05-27T14:00:00Z"
  moon := Time.parse "1969-07-20T20:17:00Z"

  expect-equals "- $erik\n- $moon\n" (yaml.stringify [erik, moon] time-converter)
  expect-equals "- $erik\n- $moon\n" (yaml.stringify [erik, moon] stringify-converter)

  fb1 := FooBar 1 2
  fb2 := FooBar "Tweedledum" "Tweedledee"

  to-json-converter := : | obj | obj.to-json  // Returns a short-lived object which is serialized.

  expect-equals
      """
      - foo: 1
        bar: 2
      - foo: Tweedledum
        bar: Tweedledee
      """
      (yaml.stringify [fb1, fb2] to-json-converter)

  // Nested custom conversions.
  fb3 := FooBar fb1 fb2
  fb3_expected :=
      """
      foo:
        foo: 1
        bar: 2
      bar:
        foo: Tweedledum
        bar: Tweedledee
      """

  print "expected: $fb3_expected.to-byte-array"
  print "produced: $((yaml.stringify fb3 to-json-converter).to-byte-array)"
  expect-equals
      fb3_expected
      (yaml.stringify fb3 to-json-converter)

  // Using a lambda instead of a block.
  to-json-lambda := :: | obj | obj.to-json  // Returns a short-lived object which is serialized.
  expect-equals
      """
      foo:
        foo: 1
        bar: 2
      bar:
        foo: Tweedledum
        bar: Tweedledee
      """
      (yaml.stringify fb3 to-json-lambda)

  byte-array-converter := : | obj encoder |
    encoder.put-list obj.size
      : | index | obj[index]    // Generator block returns integers.
      : unreachable             // Converter block will never be called since all elements are integers.

  expect-equals
      """
      - 1
      - 2
      - 42
      - 103
      """
      yaml.stringify #[1, 2, 42, 103] byte-array-converter

class FooBar:
  foo := ?
  bar := ?

  constructor .foo .bar:

  to-json -> Map:
    return { "foo": foo, "bar": bar }

test-parse:
  expect-equals "testing" (yaml.parse "\"testing\"")
  expect-equals "€" (yaml.parse "\"€\"")
  expect-equals "🙈" (yaml.parse "\"🙈\"")  // We allow JSON that doesn't use surrogates.
  expect-equals "🙈" (yaml.parse "\"\\ud83d\\ude48\"")  // JSON can also use escaped surrogates.
  expect-equals "x🙈y" (yaml.parse "\"x\\ud83d\\ude48y\"")  // JSON can also use escaped surrogates.
  expect-equals "x€y" (yaml.parse "\"x\\u20aCy\"")
  expect-equals "\"\"\"\"" (yaml.parse "\"\\\"\\\"\\\"\\\"\"")
  expect-equals "\\\"" (yaml.parse "\"\\\\\\\"\"")

  expect-equals "testing" (yaml.parse "\n\t \"testing\"")

  expect-equals true (yaml.parse "true")
  expect-equals false (yaml.parse "false")
  expect-equals null (yaml.parse "null")

  expect-equals "\\ \b \f \n \r \t" (yaml.parse "\"\\\\ \\b \\f \\n \\r \\t\"")

  expect-equals "{}" (yaml.stringify (yaml.parse "{}"))
  expect-equals "{\"a\":\"b\"}" (yaml.stringify (yaml.parse "{\"a\":\"b\"}"))
  expect-equals "{\"a\":\"b\"}" (yaml.stringify (yaml.parse " { \"a\" : \"b\" } "))
  expect-equals "[\"a\",\"b\"]" (yaml.stringify (yaml.parse " [ \"a\" , \"b\" ] "))

  expect-equals "=\"\\/bfnrt"
      (yaml.parse "\"\\u003d\\u0022\\u005c\\u002F\\u0062\\u0066\\u006e\\u0072\\u0074\"")

  expect-throw "UNTERMINATED_JSON_STRING": yaml.parse "\"\\u"
  expect-throw "UNTERMINATED_JSON_STRING": yaml.parse "\"\\ud"
  expect-throw "UNTERMINATED_JSON_STRING": yaml.parse "\"\\ud8"
  expect-throw "UNTERMINATED_JSON_STRING": yaml.parse "\"\\ud83"
  expect-throw "UNTERMINATED_JSON_STRING": yaml.parse "\"\\ud83d"
  expect-throw "UNTERMINATED_JSON_STRING": yaml.parse "\"\\ud83d\""
  expect-throw "UNTERMINATED_JSON_STRING": yaml.parse "\"\\ud83d\\"
  expect-throw "UNTERMINATED_JSON_STRING": yaml.parse "\"\\ud83d\\u"
  expect-throw "UNTERMINATED_JSON_STRING": yaml.parse "\"\\ud83d\\ud"
  expect-throw "UNTERMINATED_JSON_STRING": yaml.parse "\"\\ud83d\\ude"
  expect-throw "UNTERMINATED_JSON_STRING": yaml.parse "\"\\ud83d\\ude4"
  expect-throw "UNTERMINATED_JSON_STRING": yaml.parse "\"\\ud83d\\ude48"
  expect-equals "🙈" (yaml.parse "\"\\ud83d\\ude48\"")
  expect-throw "INVALID_SURROGATE_PAIR": yaml.parse "\"\\ud83d\\ud848\""

  yaml.parse UNICODE-EXAMPLE
  yaml.parse EXAMPLE

  yaml.decode UNICODE-EXAMPLE.to-byte-array
  yaml.decode EXAMPLE.to-byte-array

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
  expect-equals "testing".to-byte-array (yaml.encode "testing")

test-decode:
  expect-equals "testing" (yaml.decode "testing".to-byte-array)

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
  result := yaml.parse BIG
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
  result := yaml.parse NUMBER-ENDS-WITH
  expect-equals 123 result["foo"]
  expect-equals 155 result["bar"]
  expect-equals 103 result["baz"]
  expect-equals 42 result["fizz"][0]
  expect-equals 3.1415 result["fizz"][1]
  expect-equals 555 result["bam"]["boom"]
  expect-equals 99 result["buzz"]

  expect-throw "FLOAT_PARSING_ERROR": yaml.parse "[3.1E]"

  expect-throw "FLOAT_PARSING_ERROR": yaml.parse "[3.1M]"

  expect-throw "INVALID_JSON_CHARACTER": yaml.parse "[3.1\x01]"

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
  expect-throw error: yaml.parse str
  expect-throw error: yaml.parse " $str "
  expect-throw error: yaml.parse "[$str]"
  expect-throw error: yaml.parse "[ $str ]"
  expect-throw error: yaml.parse "{\"foo\":$str]"
  expect-throw error: yaml.parse "{\"foo\": $str ]"

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

