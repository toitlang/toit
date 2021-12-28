// Copyright (C) 2019 Toitware ApS. All rights reserved.

abstract class A:
  abstract foo

class B extends A:
  abstract bar x

class C extends B:
  abstract gee x y

main:
  C
