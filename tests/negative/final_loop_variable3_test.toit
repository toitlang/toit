// Copyright (C) 2019 Toitware ApS. All rights reserved.

bar: return false
gee f: return f.call

main:
  while foo ::= bar:
    gee:: foo = 42

  for x ::= 42; x < 10; (gee:: x++):
    print 1

  for x ::= 42; (gee ::x++) < 10; (gee x++):
    print 1
  
  for x ::= 42; bar; x:
    gee:: x++

  unresolved
