// Copyright (C) 2018 Toitware ApS. All rights reserved.

interface I:
interface I2:

class B:

class C extends B implements I:

wants_i x/I: null
wants_i2 x/I2: null

static_b -> B: return C

main:
  wants_i B
  wants_i C
  wants_i static_b as C
  wants_i2 B
  wants_i2 static_b as C
  wants_i static_b as any
  unresolved
