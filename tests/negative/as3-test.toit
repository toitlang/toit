// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface I:
interface I2:

class B:

class C extends B implements I:

wants-i x/I: null
wants-i2 x/I2: null

static-b -> B: return C

main:
  wants-i B
  wants-i C
  wants-i static-b as C
  wants-i2 B
  wants-i2 static-b as C
  wants-i static-b as any
  unresolved
