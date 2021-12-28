// Copyright (C) 2021 Toitware ApS. All rights reserved.

abstract class A:
  abstract foo x y=unresolved --named1=unresolved --named2=2
  // We would like to see a type error here, but that doesn't work right now.
  abstract bar x/int="str"
