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

/**
A PEG grammar for the semantic version.

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

  expect-match_ char/int [--on-error] -> int:
    if matched := match-char char: return matched
    return on-error.call "expected $(string.from-rune char) at position $current-position"

  expect-numeric [--on-error] -> int:
    if number := numeric_: return number
    return on-error.call "expected a numeric value at position $current-position"

  semantic-version --consume-all/bool=false -> SemanticVersionParseResult:
    return semantic-version --consume-all=consume-all --on-error=: throw "Parse error: $it"

  semantic-version --consume-all/bool=false [--on-error] -> SemanticVersionParseResult:
    optional: match-string "v"
    triple := version-core_ --on-error=on-error
    pre-releases := pre-releases_ --on-error=on-error
    build-numbers := build-numbers_ --on-error=on-error

    if consume-all and not eof: return on-error.call "not all input was consumed"

    return SemanticVersionParseResult triple pre-releases build-numbers current-position

  version-core_ [--on-error] -> TripleParseResult:
    major := expect-numeric --on-error=on-error
    minor/int? := null
    patch/int? := null
    if allow-missing-minor:
      if match-char '.':
        minor = expect-numeric --on-error=on-error
        if match-char '.':
          patch = expect-numeric --on-error=on-error
    else:
      minor = expect-match_ '.' --on-error=on-error
      minor = expect-numeric --on-error=on-error
      patch = expect-match_ '.' --on-error=on-error
      patch = expect-numeric --on-error=on-error
    return TripleParseResult major minor patch

  pre-releases_ [--on-error] -> List:
    try-parse:
      result := []
      if match-char '-':
        while true:
          if pre-release-result := pre-release_ --on-error=on-error: result.add pre-release-result
          else: break
          if not match-char '.': return result
    return []

  build-numbers_ [--on-error] -> List:
    try-parse:
      result := []
      if match-char '+':
        while true:
          result.add (build-number_ --on-error=on-error)
          if not match-char '.': return result
    return []

  pre-release_ [--on-error] -> any:
    if alphanumeric-result := alphanumeric_: return alphanumeric-result
    if numeric-result := numeric_: return numeric-result
    return on-error.call "expected an identifier or a number at position $current-position"

  build-number_ [--on-error] -> string:
    if alphanumeric-result := alphanumeric_: return alphanumeric-result
    try-parse:
      mark := mark
      if (repeat --at-least-one: digit_):
        return string-since mark
    return on-error.call "expected an identifier or digits at position $current-position"

  alphanumeric_ -> string?:
    mark := mark
    try-parse:
      if (repeat: digit_) and
         non-digit_ and
         (repeat: identifier-char_):
        return string-since mark
    return null

  identifier-char_ -> bool:
    return digit_ or non-digit_

  non-digit_ -> bool:
    if match-char '-' or letter_: return true
    return false

  numeric_ -> int?:
    if match-char '0': return 0
    mark := mark
    try-parse:
      if digit_ and (repeat: digit_):
        return int.parse (string-since mark)
    return null

  digit_ -> bool:
    return (match-range '0' '9') != null

  letter_ -> bool:
    return (match-range 'a' 'z') != null or
           (match-range 'A' 'Z') != null
