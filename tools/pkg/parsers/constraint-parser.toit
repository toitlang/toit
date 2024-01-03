// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .semantic-version-parser


class ConstraintParseResult:
  prefix/string?
  semantic-version/SemanticVersionParseResult

  constructor .prefix .semantic-version:

/*
  A PEG grammer for the constraints

  constraints ::= constraint ( ',' space* constraint )* space*
  constraint ::= prefix? semantic-version
  prefix ::= "!=" | '>=' | '<=' | "~>" |  '=' | '>' | '<' | '~' | '^'
  space := ' ' | '\t'
  In particular, no '*' productinos as in '1.*', that can be done with '^1.0.0'
*/
class ConstraintParser extends SemanticVersionParser:
  constructor constraint/string:
    super constraint

  constraints --consume-all/bool=false:
    result := []
    result.add constraint

    repeat:
      if match-char ',':
        repeat: space
        result.add constraint

    repeat: space

    if consume-all and not eof: throw "Parse error, not all input consumed"

    return result

  constraint:
    prefix := prefix
    version := semantic-version
    return ConstraintParseResult prefix version

  prefix -> string?:
    if match-string "!=": return "!="
    if match-string ">=": return ">="
    if match-string "<=": return "<="
    if match-string "~>": return "~>"
    if char := match-chars { '=', '>', '<', '~', '^'}:
      return string.from-rune char
    return ""

  space:
    match-chars { ' ', '\t' }