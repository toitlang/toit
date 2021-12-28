// Copyright (C) 2018 Toitware ApS. All rights reserved.

class Bar:
  bar:
    print "bar"

monitor Foo Bar:
  foo:
    print "foo"

main:
  foo := Foo
