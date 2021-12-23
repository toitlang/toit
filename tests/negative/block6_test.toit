// Copyright (C) 2019 Toitware ApS. All rights reserved.

foo [x] y:
  x.call y unresolved

main:
  b := (: it)
  foo b 499
  unresolved

