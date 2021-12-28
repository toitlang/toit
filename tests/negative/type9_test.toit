// Copyright (C) 2020 Toitware ApS. All rights reserved.

run x [block]: block.call x

main:
  run "str": |x/int| null
