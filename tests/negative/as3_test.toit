// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

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
