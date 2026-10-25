// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import system.assets
import system.storage
import expect show *

main:
  contents := assets.decode
  version := contents["version"].to-string
  expect-bytes-equal (ByteArray 5003: (it * 13 + 9) & 0xff) contents["payload"]
  bucket := storage.Bucket.open --flash "nrf-deploy"
  count := bucket.get "boots" --if-absent=: 0
  bucket["boots"] = count + 1
  bucket["version"] = version
  region := storage.Region.open --flash "nrf-deploy" --capacity=8192
  pattern := ByteArray 8192: (it * 17 + 3) & 0xff
  if count == 0:
    region.erase
    region.write --at=0 pattern
  expect-bytes-equal pattern (region.read --from=0 --to=8192)
  region.close
  bucket.close
  print "NRF5340 DEPLOY $version PASS boots=$(count + 1)"
