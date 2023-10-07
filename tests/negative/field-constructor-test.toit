// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  foo/int
  bar/int

  constructor.lambda .foo .bar:
    fun := :: foo
    super

  constructor.lambda2 .foo:
    fun := :: foo
    bar = 499

  constructor.block .foo:
    block := : foo
    super

  constructor.block2 .foo:
    block := : foo
    bar = 499

main:
  unresolved
