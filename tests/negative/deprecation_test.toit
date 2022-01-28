// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/// Deprecated. Do something else instead.
class Deprecated:
  constructor:

  /// Deprecated. Use the other constructor instead.
  constructor.named:

  method:

class A:
  /**
  Some documentation.

  # Deprecation
  Deprecated. Do something else.

  For some reasons we don't want this constructor anymore.
  */
  constructor:

  constructor.named:

  /**
  Does something.

  Deprecated. Used $method2 instead.
  */
  method1:

  /**
  This method replaces the deprecated method 1.
  We are allowed to use "Deprecated" as long as it doesn't start a
    sentence.
  */
  method2:

  /**
  A field.
  Deprecated. Use something else.
  */
  some_field := 499

  /// A static field.
  /// Deprecated. Just don't.
  static some_static_field := 42

/**
Globals too can be deprecated.

Deprecated. Find something else.
*/
global := 42

/**
Some global fun.

Deprecated. Use $bar instead.
*/
fun:

/**
This one isn't deprecated.
*/
bar:

main:
  deprecated := Deprecated
  deprecated2 := Deprecated.named
  // No warning here.
  deprecated.method

  a := A
  a2 := A.named

  a.method1
  a.method2

  a.some_field

  A.some_static_field

  global

  fun
  bar

  unresolved
