// Copyright (C) 2020 Toitware ApS. All rights reserved.

foo x/String -> String:
  return x

main:
  foo "str"
  unresolved
