// Copyright (C) 2019 Toitware ApS. All rights reserved.

import ..rpc
import .document

/**
Parameters for the document-symbol request.
*/
class DocumentSymbolParams extends MapWrapper:
  constructor json_map/Map: super json_map

  text_document -> TextDocumentIdentifier:
    return at_ "textDocument": TextDocumentIdentifier it

class SymbolKind:
  static FILE ::= 1
  static MODULE ::= 2
  static NAMESPACE ::= 3
  static PACKAGE ::= 4
  static CLASS ::= 5
  static METHOD ::= 6
  static PROPERTY ::= 7
  static FIELD ::= 8
  static CONSTRUCTOR ::= 9
  static ENUM ::= 10
  static INTERFACE ::= 11
  static FUNCTION ::= 12
  static VARIABLE ::= 13
  static CONSTANT ::= 14
  static STRING ::= 15
  static NUMBER ::= 16
  static BOOLEAN ::= 17
  static ARRAY ::= 18
  static OBJECT ::= 19
  static KEY ::= 20
  static NULL ::= 21
  static ENUM_MEMBER ::= 22
  static STRUCT ::= 23
  static EVENT ::= 24
  static OPERATOR ::= 25
  static TYPE_PARAMETER ::= 26

/**
Programming constructs like variables, classes, interfaces etc. that appear in a document.

Document symbols can be hierarchical and they have two ranges:
  * one that encloses its definition, and
  * one that points to its most interesting range, like the range of an identifier.
 */
class DocumentSymbol extends MapWrapper:
  /**
  Creates a document-symbol object.

  Parameters:
  - [name]: the name of the symbol. Must not be empty or consist of only whitespace.
  - [detail]: more information for that symbol. For example, the signature of a method.
  - [kind]: the kind of the symbol.
  - [deprecated]: optional, whether the symbol is deprecated.
  - [range]: the range enclosing this symbol, excluding whitespaces, but including comments. The
            range should allow the client to highlight the "active" symbol.
  - [selection_range]: the range to select when the user picks the symbol.
  - [children]: optional, a list of children.
  */
  constructor
      --name / string
      --detail / string? = null
      --kind / int  // A SymbolKind
      --deprecated / bool? = null
      --range / Range
      --selection_range / Range
      --children / List? = null:
    map_["name"]   = name
    map_["kind"]   = kind
    map_["detail"] = detail
    if deprecated != null: map_["deprecated"] = deprecated
    map_["range"] = range
    map_["selectionRange"] = selection_range
    if children != null: map_["children"] = children


