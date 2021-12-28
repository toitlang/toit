// Copyright (C) 2020 Toitware ApS. All rights reserved.

setter=--name x:
setter2=--optional=499 x:  optional + x
setter3=:

main:
  setter = 42
  setter2 = 499
  setter3 = 412
  setter += 42
  setter2 += 499
  setter3 += 412
