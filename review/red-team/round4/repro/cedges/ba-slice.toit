// Copyright (C) 2026 Toit contributors.
main:
  ba := ByteArray 1000: it & 0xff
  s := ba[500..600]
  print s.size
  print s[0]
  print s[99]
