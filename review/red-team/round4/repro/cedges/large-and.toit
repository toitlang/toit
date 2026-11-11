// Copyright (C) 2026 Toit contributors.
main:
  print ((1 << 62) | 1)
  print ((1 << 62) & (1 << 62))
  print ((1 << 63) ^ (1 << 62))
