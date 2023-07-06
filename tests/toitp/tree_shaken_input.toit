// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .confuse

class B:
  foo:
    return 42

class A:
  will_be_tree_shaken:
    // Pulls in `B` and makes `foo` a called selector.
    // If the tree-shaking works correctly we should neither see
    // `B` nor `foo` in the final tree.
    b := B
    (confuse b).foo

create_a -> A?:
  return null

class C:
  foo:
    return 499

main:
  a := create_a
  if a:
    // The optimizer will change the `will_be_tree_shaken` call to
    // a static call, since we know that the type must be `A`.
    // During tree-growing we will encounter 'main' first, with
    // this static call.
    // We must wait to evaluate the call until we have seen the
    // construction of `A`.
    (a as A).will_be_tree_shaken

  c := C
  confuse c
  // If the tree-shaking works, C.foo should be tree-shaken.
