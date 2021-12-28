// Copyright (C) 2020 Toitware ApS. All rights reserved.

main:
  lambda := :: |x y| x + y
  lambda.call 1
