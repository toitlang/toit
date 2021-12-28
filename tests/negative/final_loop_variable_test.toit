// Copyright (C) 2019 Toitware ApS. All rights reserved.

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
