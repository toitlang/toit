// Copyright (C) 2019 Toitware ApS. All rights reserved.

abstract x := unresolved

class A:
  abstract x := unresolved
  abstract static y := unresolved

interface B:
  x := unresolved
  abstract y := unresolved

interface C:
  constructor:
  x := unresolved
  abstract y := unresolved

main:
