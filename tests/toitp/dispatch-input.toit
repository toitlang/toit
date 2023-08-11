// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .confuse

class ClassA:
  test-foo: print "ClassA.method_a"
  test-bar x: print "ClassA.method_b 1"

class ClassB extends ClassA:
  test-bar x: print "ClassB.method_b 1"

main:
  ClassA
  (confuse ClassA).test-foo
  (confuse ClassA).test-bar 1
  (confuse ClassB).test-foo
  (confuse ClassB).test-bar 1
