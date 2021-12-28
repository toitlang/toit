// Copyright (C) 2019 Toitware ApS. All rights reserved.

interface A:
  foo

interface A2:
  bar x

class B implements A A2:
  foo: "foo"

main:
  b := B
