// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
class A2 extends A:

class B:
  param x/int -> none:
  param-wider x/A2 -> none:
  param-narrower x/A -> none:
  ret -> A: return A
  ret-unrelated -> A: return A
  ret-wider -> A2: return A2
  ret-none -> none:
  ret-any: return 1
  ret-int -> int: return 1
  untyped x: return x
  typed x/int -> int: return x
  defaults x/int=0 --named/string="" -> none:
  named --a/int --b/string -> none:
  blocks [b1] [--b2] -> none:
  field-getter -> int: return 0
  field-setter= value/int -> none:
  field-both -> A: return A
  field-both= value/A -> none:
  field-unrelated -> A: return A
  field-unrelated= value/A -> none:

class S extends B:
  param x/string -> none:  // Warning.
  param-wider x/A -> none:  // OK.
  param-narrower x/A2 -> none:  // OK.
  ret -> A2: return A2  // OK.
  ret-unrelated -> string: return ""  // Warning.
  ret-wider -> A: return A  // Warning.
  ret-none -> int: return 1  // OK.
  ret-any -> string: return ""  // OK.
  ret-int -> none:  // Warning.
  untyped x/string -> string: return x  // OK.
  typed x -> any: return x  // OK.
  defaults x/string="" --named/string="" -> none:  // Warning.
  named --b/int --a/int -> none:  // Warning on 'b'.
  blocks [b1] [--b2] -> none:  // OK.
  field-getter/string := ""  // Warning.
  field-setter/string := ""  // Warning.
  field-both/A2 := A2  // OK.
  field-unrelated/string := ""  // Warning.

// Shapes that only partially overlap.
class Shapes:
  m x/int --flag/bool=false -> none:
  n x/int y/int=0 -> none:

class Shapes2 extends Shapes:
  m x/string -> none:  // Warning.
  n x/int y/string -> none:  // Warning.

interface I:
  i x/int -> int

class C implements I:
  i x/string -> int: return 0  // Warning.

mixin M:
  mm -> int: return 0

class D extends Object with M:
  mm -> string: return ""  // Warning.

abstract class E implements I:
  abstract i x/int -> string  // Warning.

interface I2 extends I:
  i x/int -> A  // Warning.

// Override reachable through superclass and interface: reported once.
class F extends B implements I3:
  param x/string -> none:  // Warning.

interface I3:
  param x/int -> none

// Statics and constructors aren't overrides.
class G extends B:
  static param x/string -> none:
  constructor:
  constructor.ret x/string:

// Type parameters are substituted with the arguments to the supertype.
class Box<T>:
  set x/T -> none:
  get -> T?: return null
  do [block T -> none] -> none:

class SubBox<U> extends Box<U>:
  set x/U -> none:  // OK.
  get -> U?: return null  // OK.
  do [block U -> none] -> none:  // OK.

class IntBox extends Box<int>:
  set x/int -> none:  // OK.
  get -> string?: return null  // Warning.
  do [block string -> none] -> none:  // Warning.

class RawBox extends Box:
  set x/string -> none:  // OK.

main:
  S
  Shapes2
  C
  D
  F
  G
  SubBox
  IntBox
  RawBox
  unresolved
