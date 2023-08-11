// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .confuse

class B:
  foo:
    return 42

class ASuper:
  bar:
    if this is A:
      (this as A).will-be-tree-shaken

class A extends ASuper:
  will-be-tree-shaken:
    // Pulls in `B` and makes `foo` a called selector.
    // If the tree-shaking works correctly we should neither see
    // `B` nor `foo` in the final tree.
    b := B
    (confuse b).foo

class C:
  foo:
    return 499

main:
  a-super := ASuper
  a-super.bar

  c := C
  confuse c
  // If the tree-shaking works, C.foo should be tree-shaken.
