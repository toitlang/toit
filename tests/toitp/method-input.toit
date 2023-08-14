// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .confuse

class ClassA:
  constructor:
  constructor.named:

  field-a := 499
  final-field ::= 42

  method-a: print "ClassA.method_a"
  method-b x: print "ClassA.method_b 1"
  method-b x y: print "ClassA.method_b 2"

  static static-method: print "static_method"

class ClassB extends ClassA:
  method-b x: print "ClassB.method_b 1"

  final-field= x:
    // Without this setter, the optimizer will treat the
    // code that follows the illegal setting of A.final_field
    // as dead code.

global-method: print "global_method"
global-field := 0
global-lazy-field := {:}

foo [block]:
foo lambda:

class Nested:
  block:
    foo: true

  lambda:
    foo:: true

main:
  ClassA
  ClassA.named
  (ClassA).method-a
  (ClassA).method-b 1
  (ClassA).method-b 1 2

  ClassA.static-method

  (confuse ClassA).field-a
  (confuse ClassA).field-a = 499
  (confuse ClassA).final-field
  (confuse ClassA).final-field = 42

  (ClassB).method-b 1

  global-method

  global-field
  global-field = 499

  global-lazy-field["x"] = 42

  (Nested).block
  (Nested).lambda
