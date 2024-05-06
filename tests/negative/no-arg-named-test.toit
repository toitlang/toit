// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  must --no
  foo --foo
  foo2 --foo
  fizz
  fish
  block-foo --foo=0
  non-block-foo --foo=(: 0)
  block-unnamed 0

must --have:

foo --bar=null:

foo2 --bar=null --bar2=null:

fizz --bar=0 --baz:

fizz --bar=0 unnamed:

fish --hest:

fish --fisk:

block-foo [--foo]:

non-block-foo --foo:

block-unnamed [foo]:
