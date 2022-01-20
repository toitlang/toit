// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

bar: return false
gee f: return f.call

main:
  while foo ::= bar:
    foo = 42
    gee:: foo

  for x ::= 42; x < 10; x++:
    print 1
    gee:: x

  for x ::= 42; x++ < 10; x++:
    print 1
    gee:: x
  
  for x ::= 42; bar; x:
    x++
    gee:: x

  unresolved
