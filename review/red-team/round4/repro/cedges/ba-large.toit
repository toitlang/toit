// Copyright (C) 2026 Toit contributors.
main:
  ba := ByteArray 70000: it & 0xff
  print ba.size
  print ba[69999]
