// Copyright (C) 2026 Toit contributors.
main:
  f := null
  f = (:: | n/int | n == 0 ? 0 : 1 + (f.call n - 1))
  print (f.call 150)
