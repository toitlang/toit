// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

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
