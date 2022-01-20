// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo:
  // Must only be printed once.
  print "in foo"
  return 499

class C:

main:
  x / C := foo
