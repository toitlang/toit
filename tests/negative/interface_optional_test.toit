// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface I:
  foo x y=unresolved --named1=unresolved --named2=2
  // We would like to see a type error here, but that doesn't work right now.
  bar x/int="str"
