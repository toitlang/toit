// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system.assets
import system.containers

main:
  contents := assets.decode
  version := contents["version"].to-string
  expect-bytes-equal (ByteArray 5003: (it * 13 + 9) & 255) contents["payload"]
  own := containers.images.filter: it.id == containers.current
  expect-equals 1 own.size
  expect-equals "probe" own.first.name
  expect-equals 1 (own.first.flags & 1)
  expect-equals 0 (own.first.flags & 2)
  // The second container remains available for explicit start after boot.
  other := containers.images.filter: it.name == "worker"
  expect-equals 1 other.size
  expect-equals 0 (other.first.flags & 1)
  running := containers.start other.first.id
  expect-equals 0 running.wait
  running.close
  print "NRF5340 ENVELOPE $version PASS: assets, names, flags, explicit start"
