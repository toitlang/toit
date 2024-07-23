// Copyright (C) 2024 Toitware ApS.
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

import encoding.yaml.parser

class SemanticVersionParseResult:
  triple/TripleParseResult
  pre-releases/List
  build-numbers/List
  offset/int

  constructor .triple .pre-releases .build-numbers .offset:

class TripleParseResult:
  triple/List
  constructor major/int minor/int? patch/int?:
    triple = [major, minor, patch]

/*
A PEG grammar for the semantic version
semantic-version ::= "v"?
                      version-core
                      pre-releases?
                      build-numbers?
version-core ::= numeric '.' numeric '.' numeric
pre-releases ::= '-' pre-release ('.' pre-release)*
build-numbers ::= '+' build-number ('.' build-number)*

pre-release ::= alphanumeric | numeric
build-number ::= alphanumeric | digit+

alphanumeric ::= digit* non-digit identifier-char*

identifier-char ::= digit | non-digit

non-digit ::= '-' | letter
numeric ::= '0' | (digit - '0') digit *
digit ::= [0-9]
letter := [a-zA-Z]
*/

class SemanticVersionParser extends parser.PegParserBase_:
  allow-missing-minor/bool

  constructor source/string --.allow-missing-minor/bool=false:
    super source.to-byte-array

  expect-match_ char/int -> int:
    if matched := match-char char: return matched
    throw "Parse error, expected $(string.from-rune char) at position $current-position"

  expect-numeric -> int:
    if number := numeric: return number
    throw "Parse error, expected a numeric value at position $current-position"

  semantic-version --consume-all/bool=false -> SemanticVersionParseResult:
    optional: match-string "v"
    triple := version-core
    pre-releases := pre-releases
    build-numbers := build-numbers

    if consume-all and not eof: throw "Parse error, not all input was consumed"

    return SemanticVersionParseResult triple pre-releases build-numbers current-position

  version-core -> TripleParseResult:
    major := expect-numeric
    minor/int? := null
    patch/int? := null
    if allow-missing-minor:
      if match-char '.':
        minor = expect-numeric
        if match-char '.':
          patch = expect-numeric
    else:
      minor = expect-match_ '.'
      minor = expect-numeric
      patch = expect-match_ '.'
      patch = expect-numeric
    return TripleParseResult major minor patch

  pre-releases -> List:
    try-parse:
      result := []
      if match-char '-':
        while true:
          if pre-release-result := pre-release: result.add pre-release-result
          else: break
          if not match-char '.': return result
    return []

  build-numbers -> List:
    try-parse:
      result := []
      if match-char '+':
        while true:
          result.add build-number
          if not match-char '.': return result
    return []

  pre-release -> any:
    if alphanumeric-result := alphanumeric: return alphanumeric-result
    if numeric-result := numeric: return numeric-result
    throw "Parse error in pre-release, expected an identifier or a number at position $current-position"

  build-number -> string:
    if alphanumeric-result := alphanumeric: return alphanumeric-result
    try-parse:
      mark := mark
      if (repeat --at-least-one: digit):
        return string-since mark
    throw "Parse error in build-number, expected an identifier or digits at position $current-position"

  alphanumeric -> string?:
    mark := mark
    try-parse:
      if (repeat: digit) and
         non-digit and
         (repeat: identifier-char):
        return string-since mark
    return null

  identifier-char -> bool:
    return digit or non-digit

  non-digit -> bool:
    if match-char '-' or letter: return true
    return false

  numeric -> int?:
    if match-char '0': return 0
    mark := mark
    try-parse:
      if digit and (repeat: digit):
        return int.parse (string-since mark)
    return null

  digit -> bool:
    return (match-range '0' '9') != null

  letter -> bool:
    return (match-range 'a' 'z') != null or
           (match-range 'A' 'Z') != null
