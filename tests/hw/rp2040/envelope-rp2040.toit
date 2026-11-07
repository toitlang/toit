// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import device
import io.stdio
import rp2040
import system
import system.assets
import system.firmware
import system.storage
import uuid
import .storage-common show verify-persistent

main:
  expect-equals "rp2040-envelope-test" firmware.config["name"]
  expect-equals true firmware.config["enabled"]
  expect-equals "rp2040-envelope-assets" (assets.decode["payload"].to-string)
  retained := List 80: ByteArray 257 --initial=it
  40.repeat:
    system.process-stats --gc
    retained.size.repeat: | index/int | expect-equals index retained[index][256]
  bucket := storage.Bucket.open --flash "toit-rp2040-test/envelope"
  try:
    bucket["success"] = true
    expect-equals true bucket["success"]
    if firmware.config["reset-check"]: bucket.remove "success"
  finally:
    bucket.close
  if firmware.config["verify-persistence"]:
    verify-persistent
    print "envelope-rp2040: PASS existing flash bucket and region survived recovery"
  chip-id := rp2040.unique-id
  expect-equals 8 chip-id.size
  expect-equals (uuid.Uuid.uuid5 "hw_id" chip-id) device.hardware-id
  expect-equals device.hardware-id.stringify device.name
  expect (not firmware.is-validation-pending)
  expect (not firmware.is-rollback-possible)
  print "envelope-rp2040: PASS bundled container, assets, config, GC, storage RPC, and identity"
  if firmware.config["reset-check"]:
    expect-equals 0x1_0000_0001 firmware.config["large-number"]
    expect-equals "config survives reset" firmware.config["nested"]["message"]
    print "envelope-rp2040: READY reset check"
    expect-equals "RESET" (stdio.stdin.read-bytes-up-to '\n').to-string
    rp2040.reset
