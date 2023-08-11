// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  hash-code-counter := 0
  field := hash-code-counter++
  field2 := hash-code-counter
  field3 := super
  field4 := super++

  getter-setter= val:
  getter-setter: return 42

  constructor:
    field++
    getter-setter++
    this++
    super

  constructor.factory:
    field++
    getter-setter++
    this++
    super++
    return A
    

  static foo:
    field++
    getter-setter++
    this++
    super++
