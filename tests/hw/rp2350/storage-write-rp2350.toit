// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system.storage
import .storage-common show *

main:
  ram := storage.Bucket.open --ram "toit-rp2350-test/ram"
  try:
    ram["value"] = #[1, 2, 3]
    expect-equals #[1, 2, 3] ram["value"]
    ram.remove "value"
    expect-equals null (ram.get "value")
  finally:
    ram.close

  bucket := storage.Bucket.open --flash BUCKET
  try:
    bucket["marker"] = "rp2350-persistence-v1"
    bucket["large"] = payload
    bucket["small"] = #[1, 2]
    bucket["small"] = #[9, 8, 7]
    bucket["removed"] = "temporary"
    bucket.remove "removed"
  finally:
    bucket.close

  region := storage.Region.open --flash REGION --capacity=8192
  try:
    region.erase
    expect region.is-erased
    // Exercise read-modify-program across both NOR page and sector boundaries.
    region.write --at=254 #[0xaa, 0x55, 0x00, 0xfe]
    region.write --at=4095 #[0x31, 0x42, 0x53]
    expect-equals #[0xff, 0xff] (region.read --from=252 --to=254)
  finally:
    region.close
  verify-persistent
  print "storage-write-rp2350: PASS buckets, regions, page boundaries, and reopen"
