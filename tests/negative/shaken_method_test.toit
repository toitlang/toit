// Copyright (C) 2019 Toitware ApS. All rights reserved.

class A:
  foo: return 499

test a/A:
  // Because of the type-annotation we make a direct call to `foo`.
  // However, the class is never instantiated, and the method is
  //   tree-shaken.
  return a.foo

confuse x -> any: return x

main:
  test (confuse null)
