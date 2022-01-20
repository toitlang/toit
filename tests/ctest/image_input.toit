// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file
import writer

BIG1 ::= [
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

BIG_STR ::= """
DRACULA




CHAPTER I

JONATHAN HARKER'S JOURNAL

(_Kept in shorthand._)


_3 May. Bistritz._--Left Munich at 8:35 P. M., on 1st May, arriving at
Vienna early next morning; should have arrived at 6:46, but train was an
hour late. Buda-Pesth seems a wonderful place, from the glimpse which I
got of it from the train and the little I could walk through the
streets. I feared to go very far from the station, as we had arrived
late and would start as near the correct time as possible. The
impression I had was that we were leaving the West and entering the
East; the most western of splendid bridges over the Danube, which is
here of noble width and depth, took us among the traditions of Turkish
rule.

We left in pretty good time, and came after nightfall to Klausenburgh.
Here I stopped for the night at the Hotel Royale. I had for dinner, or
rather supper, a chicken done up some way with red pepper, which was
very good but thirsty. (_Mem._, get recipe for Mina.) I asked the
waiter, and he said it was called "paprika hendl," and that, as it was a
national dish, I should be able to get it anywhere along the
Carpathians. I found my smattering of German very useful here; indeed, I
don't know how I should be able to get on without it.

Having had some time at my disposal when in London, I had visited the
British Museum, and made search among the books and maps in the library
regarding Transylvania; it had struck me that some foreknowledge of the
country could hardly fail to have some importance in dealing with a
nobleman of that country. I find that the district he named is in the
extreme east of the country, just on the borders of three states,
Transylvania, Moldavia and Bukovina, in the midst of the Carpathian
mountains; one of the wildest and least known portions of Europe. I was
not able to light on any map or work giving the exact locality of the
Castle Dracula, as there are no maps of this country as yet to compare
with our own Ordnance Survey maps; but I found that Bistritz, the post
town named by Count Dracula, is a fairly well-known place. I shall enter
here some of my notes, as they may refresh my memory when I talk over my
travels with Mina.

In the population of Transylvania there are four distinct nationalities:
Saxons in the South, and mixed with them the Wallachs, who are the
descendants of the Dacians; Magyars in the West, and Szekelys in the
East and North. I am going among the latter, who claim to be descended
from Attila and the Huns. This may be so, for when the Magyars conquered
the country in the eleventh century they found the Huns settled in it. I
read that every known superstition in the world is gathered into the
horseshoe of the Carpathians, as if it were the centre of some sort of
imaginative whirlpool; if so my stay may be very interesting. (_Mem._, I
must ask the Count all about them.)

I did not sleep well, though my bed was comfortable enough, for I had
all sorts of queer dreams. There was a dog howling all night under my
window, which may have had something to do with it; or it may have been
the paprika, for I had to drink up all the water in my carafe, and was
still thirsty. Towards morning I slept and was wakened by the continuous
knocking at my door, so I guess I must have been sleeping soundly then.
I had for breakfast more paprika, and a sort of porridge of maize flour
which they said was "mamaliga," and egg-plant stuffed with forcemeat, a
very excellent dish, which they call "impletata." (_Mem._, get recipe
for this also.) I had to hurry breakfast, for the train started a little
before eight, or rather it ought to have done so, for after rushing to
the station at 7:30 I had to sit in the carriage for more than an hour
before we began to move. It seems to me that the further east you go the
more unpunctual are the trains. What ought they to be in China?

All day long we seemed to dawdle through a country which was full of
beauty of every kind. Sometimes we saw little towns or castles on the
top of steep hills such as we see in old missals; sometimes we ran by
rivers and streams which seemed from the wide stony margin on each side
of them to be subject to great floods. It takes a lot of water, and
running strong, to sweep the outside edge of a river clear. At every
station there were groups of people, sometimes crowds, and in all sorts
of attire. Some of them were just like the peasants at home or those I
saw coming through France and Germany, with short jackets and round hats
and home-made trousers; but others were very picturesque. The women
looked pretty, except when you got near them, but they were very clumsy
about the waist. They had all full white sleeves of some kind or other,
and most of them had big belts with a lot of strips of something
fluttering from them like the dresses in a ballet, but of course there
were petticoats under them. The strangest figures we saw were the
Slovaks, who were more barbarian than the rest, with their big cow-boy
hats, great baggy dirty-white trousers, white linen shirts, and enormous
heavy leather belts, nearly a foot wide, all studded over with brass
nails. They wore high boots, with their trousers tucked into them, and
had long black hair and heavy black moustaches. They are very
picturesque, but do not look prepossessing. On the stage they would be
set down at once as some old Oriental band of brigands. They are,
however, I am told, very harmless and rather wanting in natural
self-assertion.

It was on the dark side of twilight when we got to Bistritz, which is a
very interesting old place. Being practically on the frontier--for the
Borgo Pass leads from it into Bukovina--it has had a very stormy
existence, and it certainly shows marks of it. Fifty years ago a series
of great fires took place, which made terrible havoc on five separate
occasions. At the very beginning of the seventeenth century it underwent
a siege of three weeks and lost 13,000 people, the casualties of war
proper being assisted by famine and disease.

Count Dracula had directed me to go to the Golden Krone Hotel, which I
found, to my great delight, to be thoroughly old-fashioned, for of
course I wanted to see all I could of the ways of the country. I was
evidently expected, for when I got near the door I faced a
cheery-looking elderly woman in the usual peasant dress--white
undergarment with long double apron, front, and back, of coloured stuff
fitting almost too tight for modesty. When I came close she bowed and
said, "The Herr Englishman?" "Yes," I said, "Jonathan Harker." She
smiled, and gave some message to an elderly man in white shirt-sleeves,
who had followed her to the door. He went, but immediately returned with
a letter:--

     "My Friend.--Welcome to the Carpathians. I am anxiously expecting
     you. Sleep well to-night. At three to-morrow the diligence will
     start for Bukovina; a place on it is kept for you. At the Borgo
     Pass my carriage will await you and will bring you to me. I trust
     that your journey from London has been a happy one, and that you
     will enjoy your stay in my beautiful land.

"Your friend,

"DRACULA."


_4 May._--I found that my landlord had got a letter from the Count,
directing him to secure the best place on the coach for me; but on
making inquiries as to details he seemed somewhat reticent, and
pretended that he could not understand my German. This could not be
true, because up to then he had understood it perfectly; at least, he
answered my questions exactly as if he did. He and his wife, the old
lady who had received me, looked at each other in a frightened sort of
way. He mumbled out that the money had been sent in a letter, and that
was all he knew. When I asked him if he knew Count Dracula, and could
tell me anything of his castle, both he and his wife crossed themselves,
and, saying that they knew nothing at all, simply refused to speak
further. It was so near the time of starting that I had no time to ask
any one else, for it was all very mysterious and not by any means
comforting.

Just before I was leaving, the old lady came up to my room and said in a
very hysterical way:

"Must you go? Oh! young Herr, must you go?" She was in such an excited
state that she seemed to have lost her grip of what German she knew, and
mixed it all up with some other language which I did not know at all. I
was just able to follow her by asking many questions. When I told her
that I must go at once, and that I was engaged on important business,
she asked again:

"Do you know what day it is?" I answered that it was the fourth of May.
She shook her head as she said again:

"Oh, yes! I know that! I know that, but do you know what day it is?" On
my saying that I did not understand, she went on:

"It is the eve of St. George's Day. Do you not know that to-night, when
the clock strikes midnight, all the evil things in the world will have
full sway? Do you know where you are going, and what you are going to?"
She was in such evident distress that I tried to comfort her, but
without effect. Finally she went down on her knees and implored me not
to go; at least to wait a day or two before starting. It was all very
ridiculous but I did not feel comfortable. However, there was business
to be done, and I could allow nothing to interfere with it. I therefore
tried to raise her up, and said, as gravely as I could, that I thanked
her, but my duty was imperative, and that I must go. She then rose and
dried her eyes, and taking a crucifix from her neck offered it to me. I
did not know what to do, for, as an English Churchman, I have been
taught to regard such things as in some measure idolatrous, and yet it
seemed so ungracious to refuse an old lady meaning so well and in such a
state of mind. She saw, I suppose, the doubt in my face, for she put the
rosary round my neck, and said, "For your mother's sake," and went out
of the room. I am writing up this part of the diary whilst I am waiting
for the coach, which is, of course, late; and the crucifix is still
round my neck. Whether it is the old lady's fear, or the many ghostly
traditions of this place, or the crucifix itself, I do not know, but I
am not feeling nearly as easy in my mind as usual. If this book should
ever reach Mina before I do, let it bring my good-bye. Here comes the
coach!
"""

main:
  // Input to the image test.
  // The compiled program is only compiled, but not run.
  // We must ensure that interesting parts aren't removed because of tree-shaking.
  stream := file.Stream.for_write "/tmp/foo.txt"
  (writer.Writer stream).write BIG1
  (writer.Writer stream).write BIG_STR
  stream.close
