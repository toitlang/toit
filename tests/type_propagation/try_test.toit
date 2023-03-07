// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test_nested

test_nested:
  nested

nested:
  x := null
  try:
    y := null
    try:
      y = 42
    finally:
      x = y
  finally:
    return x  // Expect: smi|null
