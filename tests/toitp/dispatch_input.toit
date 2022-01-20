// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

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
