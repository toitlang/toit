// Copyright (C) 2019 Toitware ApS. All rights reserved.

class class A:
  abstract bar= x

class B extends A:
  bar= x:
    super = 22

main:
  B.bar = 42
