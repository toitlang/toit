// Copyright (C) 2020 Toitware ApS. All rights reserved.

class ClassA:
  test_foo: print "ClassA.method_a"
  test_bar x: print "ClassA.method_b 1"

class ClassB extends ClassA:
  test_bar x: print "ClassB.method_b 1"

main:
  ClassA
  (ClassA).test_foo
  (ClassA).test_bar 1
  (ClassB).test_foo
  (ClassB).test_bar 1
