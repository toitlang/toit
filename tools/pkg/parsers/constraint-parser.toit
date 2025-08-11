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

import .semantic-version-parser

class ConstraintParseResult:
  prefix/string?
  semantic-version/SemanticVersionParseResult

  constructor .prefix .semantic-version:

  stringify: return prefix ? "$prefix$semantic-version.triple.triple": semantic-version.triple.triple.stringify

/*
  A PEG grammer for the constraints

  constraints ::= constraint ( ',' space* constraint )* space*
  constraint ::= prefix? semantic-version
  prefix ::= "!=" | '>=' | '<=' | "~>" |  '=' | '>' | '<' | '~' | '^'
  space := ' ' | '\t'
  In particular, no '*' productions as in '1.*', that can be done with '^1.0.0'
*/
class ConstraintParser extends SemanticVersionParser:
  constructor constraint/string:
    super constraint

  constraints --consume-all/bool=false -> List:
    return constraints --consume-all=consume-all --on-error=: throw "Parse error: $it"

  constraints --consume-all/bool=false [--on-error]:
    result := []
    result.add (constraint_ --on-error=on-error)

    repeat:
      if match-char ',':
        repeat: space_
        result.add (constraint_ --on-error=on-error)
        true

    repeat: space_

    if consume-all and not eof:
      return on-error.call "not all input consumed"

    return result

  constraint_ [--on-error] -> ConstraintParseResult:
    prefix := prefix_
    version := semantic-version --on-error=on-error
    return ConstraintParseResult prefix version

  prefix_ -> string?:
    if match-string "!=": return "!="
    if match-string ">=": return ">="
    if match-string "<=": return "<="
    if match-string "~>": return "~>"
    if char := match-chars { '=', '>', '<', '~', '^'}:
      return string.from-rune char
    return ""

  space_:
    return match-chars { ' ', '\t' }
