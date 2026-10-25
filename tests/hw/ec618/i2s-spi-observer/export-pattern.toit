// Copyright (C) 2026 Toit contributors.
// Use of this source is governed by tests/LICENSE.
import expect show *
import host.file
import ...shared.i2s-pattern

main args:
  expect-equals 2 args.size
  bits := int.parse args[0]
  bytes := bits / 8
  compact := pattern bits --inverted
  serial := ByteArray compact.size: |offset/int|
    compact[(offset / bytes) * bytes + bytes - 1 - offset % bytes]
  file.write-contents serial --path=args[1]
