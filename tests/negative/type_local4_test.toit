// Copyright (C) 2020 Toitware ApS. All rights reserved.

foo:
  // Must only be printed once.
  print "in foo"
  return 499

class C:

main:
  x / C := foo
