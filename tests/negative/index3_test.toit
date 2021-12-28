// Copyright (C) 2019 Toitware ApS. All rights reserved.

class A:
  operator[]:
    return 499

class B:
  operator [ ] n:
  operator [] = n val:

class C:
  operator [ ]= n val:

main:
  a := A
  a[]
