// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  stop /string? := "not yet"
  while local /int? := stop:
    stop = null
  unresolved
