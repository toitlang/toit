// Copyright (C) 2019 Toitware ApS. All rights reserved.

interface A:
  foo
    log "foo"

  foo:
    print "foo"

main:
  a := A
