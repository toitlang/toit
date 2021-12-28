// Copyright (C) 2019 Toitware ApS. All rights reserved.

main:
  b := (: it)
  lambda := ::
    b.call 499
    unresolved
  lambda.call unresolved
