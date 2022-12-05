// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  x := obfuscate_null
  id (x == null)
  id (null == x)
  id ([] == x)
  id (x == [])
  id (A == A)
  id (A == null)
  id (A == x)
  id (null == A)
  id (x == A)

obfuscate_null:
  return null

class A:
  operator == other/A:
    return "hest"

id x:
  return x
