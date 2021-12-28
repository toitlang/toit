// Copyright (C) 2019 Toitware ApS. All rights reserved.

class A:
  foo x/NonExisting:
    print x

main:
  print ((A).foo 3)
