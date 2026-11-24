// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

/**
Checks a Frama-C/WP JSON report (`-wp-report-json`) for the WP jobs of
  verified/cxx/annotated/run.sh (heap/page-scan-wp.sh, loader/wp.sh,
  utf8/wp.sh). WP's exit status alone allows unproved goals.

Usage: toit run wp_report.toit -- NAME REPORT LOG PROPERTY...

Passes (prints `ok    NAME: N obligations proved`, exit status 0) when
- every goal of REPORT (a JSON list of objects with the keys `goal`,
  `property` and `verdict`) has the verdict "valid",
- every PROPERTY is the property of some goal (the named properties must be
  there: a goal that WP no longer generates is not proved), and
- WP's output LOG does not contain "Memory model hypotheses" (the proof
  would hold only under assumptions about separation that WP adds).
Otherwise prints `FAIL  NAME: ...` on stderr and exits with status 1. A
  malformed report (not a list of objects, a goal without one of the keys)
  or a file that is not UTF-8 is also a failure.
*/

import encoding.json
import host.file
import host.pipe

main args:
  if args.size < 3:
    pipe.print-to-stderr "usage: wp_report.toit NAME REPORT LOG PROPERTY..."
    exit 2
  name := args[0]
  report := args[1]
  log := args[2]
  required := args[3..]
  text := read-utf8 report
  // Toit's JSON parser accepts some texts that are not JSON (leading zeros,
  // control characters in strings); check the syntax first.
  syntax-error := (JsonSyntax_ text).check
  if syntax-error: fail name "$report is not JSON: $syntax-error"
  goals := json.parse text
  if goals is not List: fail name "$report is not a list of goals"
  properties := {}
  failed := []
  goals.do: | goal |
    if goal is not Map: fail name "$report has a goal that is not an object: $goal"
    property := goal["property"]  // Throws (a failure) without the key.
    if property is List or property is Map: fail name "$report has an unhashable property: $property"
    // Only a string can be one of the required properties.
    if property is string: properties.add property
  goals.do: | goal |
    // Checked in this order so that a missing key fails as it would have
    // in the Python checker this replaces.
    if goal["verdict"] != "valid": failed.add goal["goal"]
  missing := []
  required.do: | property |
    if not properties.contains property and not missing.contains property:
      missing.add property
  missing.sort --in-place
  hypotheses := (read-utf8 log).contains "Memory model hypotheses"
  if not failed.is-empty or not missing.is-empty or hypotheses:
    hypotheses-note := hypotheses ? ", memory model hypotheses in the log" : ""
    fail name "see $log (unproved $(json.stringify failed), missing $(json.stringify missing)$hypotheses-note)"
  print "ok    $name: $goals.size obligations proved"

/** The contents of the file $path; throws when it is not valid UTF-8. */
read-utf8 path/string -> string:
  return (file.read-contents path).to-string

fail name/string message/string -> none:
  pipe.print-to-stderr "FAIL  $name: $message"
  exit 1

/**
A syntax check of JSON text (RFC 8259): one value, surrounded by optional
  whitespace (space, tab, newline, carriage return).
*/
class JsonSyntax_:
  bytes_/ByteArray
  pos_ := 0

  constructor text/string:
    bytes_ = text.to-byte-array

  /** Null when the text is JSON, else a description of the first error. */
  check -> string?:
    exception := catch:
      skip-space_
      value_
      skip-space_
      if pos_ != bytes_.size: throw "trailing text"
    if exception: return "$exception at byte $pos_"
    return null

  peek_ -> int?:
    return pos_ < bytes_.size ? bytes_[pos_] : null

  expect_ c/int -> none:
    if peek_ != c: throw "expected '$(string.from-rune c)'"
    pos_++

  skip-space_ -> none:
    while (peek_ == ' ' or peek_ == '\t' or peek_ == '\n' or peek_ == '\r'): pos_++

  literal_ word/string -> none:
    word.to-byte-array.do: expect_ it

  value_ -> none:
    c := peek_
    if c == '{':
      pos_++
      skip-space_
      if peek_ == '}':
        pos_++
        return
      while true:
        skip-space_
        string_
        skip-space_
        expect_ ':'
        skip-space_
        value_
        skip-space_
        if peek_ == '}':
          pos_++
          return
        expect_ ','
    else if c == '[':
      pos_++
      skip-space_
      if peek_ == ']':
        pos_++
        return
      while true:
        skip-space_
        value_
        skip-space_
        if peek_ == ']':
          pos_++
          return
        expect_ ','
    else if c == '"':
      string_
    else if c == 't':
      literal_ "true"
    else if c == 'f':
      literal_ "false"
    else if c == 'n':
      literal_ "null"
    else if c == '-' or (c and '0' <= c <= '9'):
      number_
    else:
      throw "unexpected character"

  string_ -> none:
    expect_ '"'
    while true:
      c := peek_
      if c == null: throw "unterminated string"
      if c < 0x20: throw "control character in a string"
      pos_++
      if c == '"': return
      if c == '\\':
        e := peek_
        if e == 'u':
          pos_++
          4.repeat:
            h := peek_
            if not (h and ('0' <= h <= '9' or 'a' <= h <= 'f' or 'A' <= h <= 'F')):
              throw "invalid \\u escape"
            pos_++
        else if e == '"' or e == '\\' or e == '/' or e == 'b' or e == 'f' or e == 'n' or e == 'r' or e == 't':
          pos_++
        else:
          throw "invalid escape"

  digits_ -> none:
    if not (peek_ and '0' <= peek_ <= '9'): throw "expected a digit"
    while peek_ and '0' <= peek_ <= '9': pos_++

  number_ -> none:
    if peek_ == '-': pos_++
    if peek_ == '0':
      pos_++
    else:
      digits_
    if peek_ == '.':
      pos_++
      digits_
    if peek_ == 'e' or peek_ == 'E':
      pos_++
      if peek_ == '+' or peek_ == '-': pos_++
      digits_
