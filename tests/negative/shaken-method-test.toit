// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ..confuse

class A:
  foo: return 499

test a/A:
  // Because of the type-annotation we make a direct call to `foo`.
  // However, the class is never instantiated, and the method is
  //   tree-shaken.
  return a.foo

main:
  test (confuse null)
