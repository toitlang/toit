// Copyright (C) 2021 Toitware ApS. All rights reserved.

class A:
  operator [..] --from --to --other:
    return from + to

class B:
  operator [..] --from=499 --to:
    return from + to

class C:
  operator [..] --from --to=42:
    return from + to

class D:
  operator [..]:
  operator [ .. ] --from --to:
  operator [..] --from:

main:
  b := B
  b[0..]
  b[..]

  c := C
  c[..0]
  c[..]

  outside := 1..2
