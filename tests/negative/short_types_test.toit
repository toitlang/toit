// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

int := 0
float := 1.0
bool := true

foo x/int -> int: return x + 1
bar y/bool -> bool: return not y
gee z/float -> float: return -z

main:
  1 is int
  1.0 is float
  true is bool
