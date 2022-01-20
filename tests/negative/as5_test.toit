// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:

class B extends A:

main:
  b := B  // Instantiate, so that the `as` test isn't constant-folded.
  A as B
