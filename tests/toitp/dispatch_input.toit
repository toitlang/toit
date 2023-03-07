// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class ClassA:
  test_foo: print "ClassA.method_a"
  test_bar x: print "ClassA.method_b 1"

class ClassB extends ClassA:
  test_bar x: print "ClassB.method_b 1"

confuse a:
  return a

main:
  ClassA
  (confuse ClassA).test_foo
  (confuse ClassA).test_bar 1
  (confuse ClassB).test_foo
  (confuse ClassB).test_bar 1
