// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface A:

class B:

class C implements A:

main:
  c := C  // Instantiate C, so that the `as` check isn't constant folded.
  B as A
