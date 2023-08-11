// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class ClassA:
  field := 0

class ClassB extends ClassA:
  field-b := 0

main:
  ClassA
  ClassB
