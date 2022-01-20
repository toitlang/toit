// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests the entire process exits with exit value 1.
main:
  task::
    task::
      task:: throw "oops"
