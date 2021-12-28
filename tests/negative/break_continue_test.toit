// Copyright (C) 2019 Toitware ApS. All rights reserved.

foo:
  while true:
    (:: break).call
    (:: continue).call
  unresolved

bar:
  while true:
    gee:
      (:: break).call
      (:: continue).call
      unresolved

gee [block]: block.call

main:
  break
  continue
  unresolved
