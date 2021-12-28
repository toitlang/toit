// Copyright (C) 2019 Toitware ApS. All rights reserved.

interface A:
  x := null

class B implements A:
  x := 499

main:
  b := B
