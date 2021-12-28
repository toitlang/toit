// Copyright (C) 2021 Toitware ApS. All rights reserved.

main:
  task::
    throw "nope"

  while true:
    sleep --ms=1000
    print "tada"
