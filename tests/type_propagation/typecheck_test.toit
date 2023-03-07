// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test_simple
  test_any
  test_throws

test_simple:
  id (is_int null)
  id (is_int 7)
  id (is_int 7.9)
  id (is_int "kurt")

test_any:
  id (7 is any)
  id ("hest" is any)
  id (7 as any)
  id ("hest" as any)

test_throws:
  catch: foo as string
  catch: bar (7 as any)

foo:
  return 42

bar x/string:
  return 99

is_int x:
  return x is int

id x:
  return x
