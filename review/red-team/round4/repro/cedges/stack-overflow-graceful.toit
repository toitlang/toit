// Copyright (C) 2026 Toit contributors.
main:
  f := null
  f = (:: | n/int | n == 0 ? 0 : 1 + (f.call n - 1))
  print (catch: f.call 100000)
