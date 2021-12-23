// Copyright (C) 2019 Toitware ApS. All rights reserved.

class A:
  x := null

  constructor:
    x --val=499

class B extends A:
  x val:
    print "subclass would accept 'val'"


main:
  b := B
