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

import .summary

abstract class Node:
  abstract accept visitor / ToitdocVisitor

class Contents extends Node:
  sections / List ::= ?

  constructor .sections:

  accept visitor / ToitdocVisitor:
    return visitor.visit_Contents this

class Section extends Node:
  title / string? ::= ?
  statements / List ::= ?

  constructor .title .statements:

  accept visitor / ToitdocVisitor:
    return visitor.visit_Section this

abstract class Statement extends Node:

class CodeSection extends Statement:
  text / string ::= ?

  constructor .text:

  accept visitor / ToitdocVisitor:
    return visitor.visit_CodeSection this

class Itemized extends Statement:
  items / List ::= ?

  constructor .items:

  accept visitor / ToitdocVisitor:
    return visitor.visit_Itemized this

class Item extends Node:
  statements / List ::= ?

  constructor .statements:

  accept visitor / ToitdocVisitor:
    return visitor.visit_Item this

class Paragraph extends Statement:
  expressions / List ::= ?

  constructor .expressions:

  accept visitor / ToitdocVisitor:
    return visitor.visit_Paragraph this

abstract class Expression extends Node:

class Text extends Expression:
  text / string ::= ?

  constructor .text:

  accept visitor / ToitdocVisitor:
    return visitor.visit_Text this

class Code extends Expression:
  text / string ::= ?

  constructor .text:

  accept visitor / ToitdocVisitor:
    return visitor.visit_Code this

class Shape:
  arity / int ::= -1
  total_block_count / int ::= -1
  named_block_count / int ::= -1
  is_setter / bool ::= false
  names / List ::= ?

  constructor
      --.arity
      --.total_block_count
      --.named_block_count
      --.is_setter
      --.names:

class ToitdocRef extends Expression:
  static OTHER ::= 0
  static CLASS ::= 1
  static GLOBAL ::= 2
  static GLOBAL_METHOD ::= 3
  static STATIC_METHOD ::= 4
  static CONSTRUCTOR ::= 5
  static FACTORY ::= 6
  static METHOD ::= 7
  static FIELD ::= 8

  text       / string  ::= ?
  kind       / int     ::= ?
  module_uri / string? ::= null
  holder     / string? ::= null
  name       / string? ::= null
  shape      / Shape?  ::= null

  constructor.other .text:
    kind = OTHER

  constructor
      --.text
      --.kind
      --.module_uri
      --.holder
      --.name
      --.shape:

  accept visitor / ToitdocVisitor:
    return visitor.visit_ToitdocRef this

interface ToitdocVisitor:
  visit_Contents    node / Contents
  visit_Section     node / Section
  visit_CodeSection node / CodeSection
  visit_Itemized    node / Itemized
  visit_Item        node / Item
  visit_Paragraph   node / Paragraph
  visit_Text        node / Text
  visit_Code        node / Code
  visit_ToitdocRef  node / ToitdocRef
