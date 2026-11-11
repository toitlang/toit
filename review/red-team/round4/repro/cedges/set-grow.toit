// Copyright (C) 2026 Toit contributors.
main:
  s := {}
  3000.repeat: s.add (it % 1009)
  print s.size
