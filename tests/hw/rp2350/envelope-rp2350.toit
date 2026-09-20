// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import device
import rp2350
import system
import system.assets
import system.firmware
import system.storage
import uuid
import .storage-common show verify-persistent

main:
  expect-equals "rp2350-envelope-test" firmware.config["name"]
  expect-equals true firmware.config["enabled"]
  expect-equals "rp2350-envelope-assets" (assets.decode["payload"].to-string)
  retained := List 80: ByteArray 257 --initial=it
  40.repeat:
    system.process-stats --gc
    retained.size.repeat: | index/int | expect-equals index retained[index][256]
  bucket := storage.Bucket.open --flash "toit-rp2350-test/envelope"
  try:
    bucket["success"] = true
    expect-equals true bucket["success"]
  finally:
    bucket.close
  if firmware.config["verify-persistence"]:
    verify-persistent
    print "envelope-rp2350: PASS existing flash bucket and region survived recovery"
  chip-id := rp2350.unique-id
  expect-equals 8 chip-id.size
  expect-equals (uuid.Uuid.uuid5 "hw_id" chip-id) device.hardware-id
  expect-equals device.hardware-id.stringify device.name
  // Production envelopes delegate validation to their boot applications.
  firmware.validate
  print "envelope-rp2350: PASS bundled container, assets, config, GC, storage RPC, and identity"
