// Copyright (C) 2025 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  foo false
  foo2 false

bar:
  return true

foo x=bar:
  if x:
    print x

foo2 x=true:
  if x:
    print x
