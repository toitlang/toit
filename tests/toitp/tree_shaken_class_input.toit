// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  static foo: return 499

bar: return 42

class B:
  static gee: return 1

class C:
  static toto: return 99

class D extends C:

main args:
  print A.foo
  print bar
  B
  B.gee
  maybe_d := args.size == 3 ? D : B
  // By using the C class in an as-check it's still in the
  // source-mapping, but isn't instantiated.
  maybe_d as C
  C.toto
