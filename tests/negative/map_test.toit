// Copyright (C) 2019 Toitware ApS. All rights reserved.

main:
  x := {
    1 :
  }
  unresolved

  x = {
    1 : unresolved,
    unresolved
  }

  x = {
    unresolved : true,
    break 499
  }
