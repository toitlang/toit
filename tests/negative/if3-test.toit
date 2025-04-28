// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

toto [block]:

main:
  if true:
      print "something"
    else:
      unresolved


  toto: if true:
        print "something"
      // No warning here, though.
      else:
          unresolved
