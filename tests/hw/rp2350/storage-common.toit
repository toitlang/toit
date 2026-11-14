// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system.storage

BUCKET ::= "toit-rp2350-test/persistent"
REGION ::= "toit-rp2350-test/region"

payload -> ByteArray:
  return ByteArray 8193: (it * 37 + 11) & 255

verify-persistent:
  bucket := storage.Bucket.open --flash BUCKET
  try:
    expect-equals "rp2350-persistence-v1" bucket["marker"]
    expect-equals payload bucket["large"]
    expect-equals #[9, 8, 7] bucket["small"]
    expect-equals null (bucket.get "removed")
  finally:
    bucket.close
  region := storage.Region.open --flash REGION
  try:
    expect-equals 4096 region.erase-granularity
    expect-equals #[0xaa, 0x55, 0x00, 0xfe] (region.read --from=254 --to=258)
    expect-equals #[0x31, 0x42, 0x53] (region.read --from=4095 --to=4098)
    expect-equals #[0xff, 0xff] (region.read --from=4093 --to=4095)
  finally:
    region.close
