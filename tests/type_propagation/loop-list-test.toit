// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  list := [0]
  while list.size < 100:
    list.add list.size + list.last
  if 4950 != list.last: throw "Bad computation"
