// Copyright (C) 2019 Toitware ApS. All rights reserved.

interface A:
  foo

interface A2 implements A:
  bar x

class B implements A2:
  bar x: "bar"

main:
  b := B
