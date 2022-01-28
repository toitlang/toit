// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  foo := 1
  foo:
    return "clash"
  foo= x:
    "clash too"

main:
  print (A).foo
