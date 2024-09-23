// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .deprecation2-lib
import .deprecation2-lib show foo

/// Deprecated.
class Deprecated:
  constructor:

  /// Deprecated.
  constructor.named:

  method:

class A:
  /**
  Some documentation.

  # Deprecation
  Deprecated.

  For some reasons we don't want this constructor anymore.
  */
  constructor:

  constructor.named:

  /**
  Does something.

  Deprecated.
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
  Deprecated.
  */
  some-field := 499

  /// A static field.
  /// Deprecated.
  static some-static-field := 42

/**
Globals too can be deprecated.

Deprecated.
*/
global := 42

/**
Some global fun.

Deprecated.
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

  a.some-field

  A.some-static-field

  global

  fun
  bar

  unresolved
