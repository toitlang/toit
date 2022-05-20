// Copyright (C) 2019 Toitware ApS.
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
The kind of a code action.

Kinds are a hierarchical list of identifiers separated by `.`, e.g. `"refactor.extract.function"`.

The set of kinds is open and client needs to announce the kinds it supports to the server during
  initialization.
*/
// TODO(florian): this should be an enum.
class CodeActionKind:
  /**
  Base kind for quickfix actions: 'quickfix'
  */
  static quick_fix ::= "quickfix"

  /**
  Base kind for refactoring actions: 'refactor'
  */
  static refactor ::= "refactor"

  /**
  Base kind for refactoring extraction actions: 'refactor.extract'

  Example extract actions:
  - Extract method
  - Extract function
  - Extract variable
  - Extract interface from class
  - ...
  */
  static refactor_extract ::= "refactor.extract"

  /**
  Base kind for refactoring inline actions: 'refactor.inline'

  Example inline actions:
  - Inline function
  - Inline variable
  - Inline constant
  - ...
  */
  static refactor_inline ::= "refactor.inline"

  /**
  Base kind for refactoring rewrite actions: 'refactor.rewrite'

  Example rewrite actions:
  - Convert JavaScript function to class
  - Add or remove parameter
  - Encapsulate field
  - Make method static
  - Move method to base class
  - ...
  */
  static refactor_rewrite ::= "refactor.rewrite"

  /**
  Base kind for source actions: `source`

  Source code actions apply to the entire file.
  */
  static source ::= "source"

  /**
  Base kind for an organize imports source action: `source.organizeImports`
  */
  static source_organize_imports ::= "source.organizeImports"
