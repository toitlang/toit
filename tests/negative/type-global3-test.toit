// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo/int := (::
    // Since the bar assignment happens inside the body of a global, we
    // can't just do globals first to resolve their types.
    bar = ("str" as any)
    0
  ).call

bar/int := 499

main:
  foo
