// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  fooX: return 499

bar -> A: return confuse null

foo:
  return bar.fooX

confuse x -> any: return x

main:
  print foo
