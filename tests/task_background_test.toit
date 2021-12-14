// Copyright (C) 2021 Toitware ApS. All rights reserved.

main:
  count := 3
  count.repeat:
    task --background::
      10000.repeat:
        yield
      count--

  while count > 0:
    sleep --ms=10

  print "All done"
