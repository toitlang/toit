// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

bar: return false

main:
  while foo ::= bar:
    foo = 42

  for x ::= 42; x < 10; x++:
    print 1

  for x ::= 42; x++ < 10; x++:
    print 1
  
  for x ::= 42; bar; x:
    x++

  unresolved
