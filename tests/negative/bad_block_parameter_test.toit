// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo [block]: block.call

main:
  foo: |export| unresolved
  foo: |for x: | unresolved
  foo: |for
  foo: unresolved
  foo: |4
  foo: |
