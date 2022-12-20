// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test_simple

test_simple:
  id (is_int null)
  id (is_int 7)
  id (is_int 7.9)
  id (is_int "kurt")

is_int x:
  return x is int

id x:
  return x
