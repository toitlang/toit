// Copyright (C) 2020 Toitware ApS. All rights reserved.

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
