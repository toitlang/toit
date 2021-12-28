// Copyright (C) 2020 Toitware ApS. All rights reserved.

foo x:
  #primitive.core.string_hash_code:
    return::
      x += "1"
      x

bar fun -> any: return fun.call

class A:
  constructor:

  constructor len:
    #primitive.core.string_hash_code:
      return bar::
        len += "1"
        len

main:
  foo "str"
  A 10
