// Copyright (C) 2019 Toitware ApS. All rights reserved.

main:
  b := : |foo| print foo
  b.call --foo=unresolved
  unresolved
