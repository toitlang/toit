// Copyright (C) 2026 Toit contributors.
main:
  m := {:}
  3000.repeat: m[it] = it * 3
  print m.size
  print m[2999]
  print (m.get 5000)
