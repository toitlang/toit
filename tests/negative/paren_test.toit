// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo x:
 (1 +
 unresolved

foo x y:
 (1 + 3
 unresolved

main:
  foo 1
