// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ..confuse

class A:
  fooX: return 499

bar -> A: return confuse null

foo:
  return bar.fooX

main:
  print foo
