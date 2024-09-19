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
    return visitor.visit-Contents this

class Section extends Node:
  title / string? ::= ?
  level / int ::= ?
  statements / List ::= ?

  constructor .title .level .statements:

  accept visitor / ToitdocVisitor:
    return visitor.visit-Section this

abstract class Statement extends Node:

class CodeSection extends Statement:
  text / string ::= ?

  constructor .text:

  accept visitor / ToitdocVisitor:
    return visitor.visit-CodeSection this

class Itemized extends Statement:
  items / List ::= ?

  constructor .items:

  accept visitor / ToitdocVisitor:
    return visitor.visit-Itemized this

class Item extends Node:
  statements / List ::= ?

  constructor .statements:

  accept visitor / ToitdocVisitor:
    return visitor.visit-Item this

class Paragraph extends Statement:
  expressions / List ::= ?

  constructor .expressions:

  accept visitor / ToitdocVisitor:
    return visitor.visit-Paragraph this

abstract class Expression extends Node:

class Text extends Expression:
  text / string ::= ?

  constructor .text:

  accept visitor / ToitdocVisitor:
    return visitor.visit-Text this

class Code extends Expression:
  text / string ::= ?

  constructor .text:

  accept visitor / ToitdocVisitor:
    return visitor.visit-Code this

class Shape:
  arity / int ::= -1
  total-block-count / int ::= -1
  named-block-count / int ::= -1
  is-setter / bool ::= false
  names / List ::= ?

  constructor
      --.arity
      --.total-block-count
      --.named-block-count
      --.is-setter
      --.names:

class ToitdocRef extends Expression:
  static OTHER ::= 0
  static CLASS ::= 1
  static GLOBAL ::= 2
  static GLOBAL-METHOD ::= 3
  static STATIC-METHOD ::= 4
  static CONSTRUCTOR ::= 5
  static FACTORY ::= 6
  static METHOD ::= 7
  static FIELD ::= 8
  static PARAMETER ::= 9

  text       / string  ::= ?
  kind       / int     ::= ?
  module-uri / string? ::= null
  holder     / string? ::= null
  name       / string? ::= null
  shape      / Shape?  ::= null

  constructor.other .text:
    kind = OTHER

  constructor.parameter .text:
    kind = PARAMETER

  constructor
      --.text
      --.kind
      --.module-uri
      --.holder
      --.name
      --.shape:

  accept visitor / ToitdocVisitor:
    return visitor.visit-ToitdocRef this

class Link extends Expression:
  text / string ::= ?
  url  / string ::= ?

  constructor .text .url:

  accept visitor / ToitdocVisitor:
    return visitor.visit-Link this

interface ToitdocVisitor:
  visit-Contents    node / Contents
  visit-Section     node / Section
  visit-CodeSection node / CodeSection
  visit-Itemized    node / Itemized
  visit-Item        node / Item
  visit-Paragraph   node / Paragraph
  visit-Text        node / Text
  visit-Code        node / Code
  visit-Link        node / Link
  visit-ToitdocRef  node / ToitdocRef
