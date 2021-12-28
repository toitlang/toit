// Copyright (C) 2019 Toitware ApS. All rights reserved.

operator [] x:
  unresolved x

operator []= x v:
  unresolved x v

operator [ x:
  unresolved x

operator [ = x:
  unresolved x

class A:
  static operator [] x:
    unresolved
  static operator []= x v:
    unresolved
  static operator [ x v:
    unresolved x v
  static operator [ = x v:
    unresolved x v

main:
