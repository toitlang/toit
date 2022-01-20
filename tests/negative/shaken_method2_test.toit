// Copyright (C) 2022 Toitware ApS. All rights reserved.

class A:
  foo: return 499

class B:

bar:
  return B

test a/A = bar:
  // Because of the type-annotation we make a direct call to `foo`.
  // However, the class is never instantiated, and the method is
  //   tree-shaken.
  return a.foo

main:
  test null
