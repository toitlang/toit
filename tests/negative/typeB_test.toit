// Copyright (C) 2020 Toitware ApS. All rights reserved.

run x [block]: block.call x

run x fun/Lambda: fun.call x

main:
  run 499: |it/string|
    it.copy 1
