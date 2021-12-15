// Copyright (C) 2020 Toitware ApS. All rights reserved.

main:
  cow / any := #[1, 2, 3, 4, 5, 6]
  backing := cow.backing_
  // Should be a segmentation fault to try to change the backing store.
  backing[2] = 5
