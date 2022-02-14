// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class ClassA:
  constructor:
  constructor.named:

  field_a := 499
  final_field ::= 42

  method_a: print "ClassA.method_a"
  method_b x: print "ClassA.method_b 1"
  method_b x y: print "ClassA.method_b 2"

  static static_method: print "static_method"

class ClassB extends ClassA:
  method_b x: print "ClassB.method_b 1"

global_method: print "global_method"
global_field := 0
global_lazy_field := {:}

foo [block]:
foo lambda:

class Nested:
  block:
    foo: true

  lambda:
    foo:: true

confuse x -> any: return x

main:
  ClassA
  ClassA.named
  (ClassA).method_a
  (ClassA).method_b 1
  (ClassA).method_b 1 2

  ClassA.static_method

  (confuse ClassA).field_a
  (confuse ClassA).field_a = 499
  (confuse ClassA).final_field
  (confuse ClassA).final_field = 42

  (ClassB).method_b 1

  global_method

  global_field
  global_field = 499

  global_lazy_field["x"] = 42

  (Nested).block
  (Nested).lambda
