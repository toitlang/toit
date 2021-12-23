// Copyright (C) 2020 Toitware ApS. All rights reserved.

main:
  x := null
  x = "str"
  if Time.now.s_since_epoch == 0: x = 499
  x as int
