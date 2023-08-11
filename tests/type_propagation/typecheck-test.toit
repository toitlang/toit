// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test-simple
  test-any
  test-throws

test-simple:
  id (is-int null)
  id (is-int 7)
  id (is-int 7.9)
  id (is-int "kurt")

test-any:
  id (7 is any)
  id ("hest" is any)
  id (7 as any)
  id ("hest" as any)

test-throws:
  catch: foo as string
  catch: bar (7 as any)

foo:
  return 42

bar x/string:
  return 99

is-int x:
  return x is int

id x:
  return x
