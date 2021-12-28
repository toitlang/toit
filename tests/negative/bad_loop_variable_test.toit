// Copyright (C) 2019 Toitware ApS. All rights reserved.

import core as pre

main:
  while this := 499: print 1
  while foo.bar := 42: print 2
  while pre.bar := 42: print 2
  while 42 := 42: print 3
  while this ::= 499: print 1
  while foo.bar ::= 42: print 2
  while pre.bar ::= 42: print 2
  while 42 ::= 42: print 3

  for this := 499; true; true: print 1
  for foo.bar := 499; true; true: print 1
  for pre.bar := 499; true; true: print 1
  for 42 := 499; true; true: print 1
  for this ::= 499; true; true: print 1
  for foo.bar ::= 499; true; true: print 1
  for pre.bar ::= 499; true; true: print 1
  for 42 ::= 499; true; true: print 1
