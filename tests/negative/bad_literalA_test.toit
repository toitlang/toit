// Copyright (C) 2018 Toitware ApS. All rights reserved.

main:
  // This is just a lookup failure, since the syntax is similar to a call, like
  // in `0.abs`
  print 0x.123456P
  print 0x.123456P+
  print 0x.123456p-
  print 0x.123456p+5_
  print 0x.123456p-_3
  print 0x.123456
  print 0xabc.123456
  print 0xabc.123456p-
  print 0xabc.123456P+5_
  print 0xabc.123456P-_3
  unresolved
