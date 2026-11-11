// Copyright (C) 2026 Toit contributors.
main:
  l := List 5000: it
  print l.size
  print l[4999]
  print (l.reduce: | a b | a + b)
