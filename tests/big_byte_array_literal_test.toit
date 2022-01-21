// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Should compile to a byte-array in the snapshot.
BIG1 ::= #[
  0,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 1,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 2,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 3,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 4,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 5,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 6,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 7,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 8,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 9,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,  // 1000 bytes.
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 1,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 2,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 3,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 4,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 5,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 6,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 7,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 8,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 9,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,  // 2000 bytes.
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 1,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 2,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 3,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 4,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 5,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 6,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 7,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 8,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 9,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,  // 3000 bytes.
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 1,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 2,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 3,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 4,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 5,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 6,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 7,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 8,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 9,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,  // 4000 bytes.
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 1,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 2,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 3,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 4,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 5,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 6,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 7,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 8,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 9,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,  // 5000 bytes.
]

BIG2 ::= #[
  0,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 1,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 2,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 3,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 4,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 5,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 6,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 7,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 8,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 9,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,  // 1000 bytes.
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 1,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 2,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 3,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 4,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 5,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 6,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 7,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 8,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 9,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,  // 2000 bytes.
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 1,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 2,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 3,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 4,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 5,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 6,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 7,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 8,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 9,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,  // 3000 bytes.
]

BIG3 ::= #[
  0,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 1,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 2,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 3,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 4,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 5,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 6,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 7,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 8,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 9,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,  // 1000 bytes.
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 1,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 2,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 3,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 4,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 5,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 6,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 7,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 8,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 9,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,  // 2000 bytes.
]

BIG4 ::= #[
  0,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 1,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 2,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 3,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 4,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 5,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 6,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 7,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 8,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 9,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 20,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 30,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 40,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 50,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 60,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 70,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 80,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 90,
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10,  // 1000 bytes.
]

main:
  expect_equals 5001 BIG1.size
  expect_equals 3001 BIG2.size
  expect_equals 2001 BIG3.size
  expect_equals 1001 BIG4.size
  lists := [BIG1, BIG2, BIG3, BIG4]
  lists.do: |big|
    expect (big is CowByteArray_)
    for i := 0; i < big.size; i++:
      if i % 1000 == 0:
        expect_equals (i / 100) big[i]
      else if i % 100 == 0:
        expect_equals ((i / 100) % 10) big[i]
      else if i % 10 == 0:
        expect_equals (i % 100) big[i]
