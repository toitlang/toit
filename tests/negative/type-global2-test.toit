// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo/int := 499

bar/int := (::
    // Since the foo assignment happens inside the body of a global, we
    // can't just do globals first to resolve their types.
    foo = ("str" as any)
    0
  ).call

main:
  bar
