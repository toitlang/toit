// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  cow / any := #[1, 2, 3, 4, 5, 6]
  backing := cow.backing_
  // Should be a segmentation fault to try to change the backing store.
  backing[2] = 5
