// Copyright (C) 2019 Toitware ApS. All rights reserved.

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
