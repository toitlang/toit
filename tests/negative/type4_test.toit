// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  foo x -> NonExisting:
    print x
    unreachable

main:
  print ((A).foo 3)
