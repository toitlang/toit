// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  hash_code_counter := 0
  field := hash_code_counter++
  field2 := hash_code_counter
  field3 := super
  field4 := super++

  getter_setter= val:
  getter_setter: return 42

  constructor:
    field++
    getter_setter++
    this++
    super

  constructor.factory:
    field++
    getter_setter++
    this++
    super++
    return A
    

  static foo:
    field++
    getter_setter++
    this++
    super++
