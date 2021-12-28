// Copyright (C) 2020 Toitware ApS. All rights reserved.

main:
  stop /string? := "not yet"
  while local /int? := stop:
    stop = null
  unresolved
