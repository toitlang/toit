// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo x:
  #primitive.core.string_hash_code:
    return::
      x += "1"
      x

bar func -> any: return func.call

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
