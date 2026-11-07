// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import io.stdio
import system
import system.assets
import system.firmware
import system.storage
import .firmware-stream-common show STATE current-digest

main:
  size := int.parse assets.decode["size"].to-string
  checksum/ByteArray := assets.decode["sha256"]
  before := current-digest
  ticks := 0
  collector := task::
    while true:
      system.process-stats --gc
      ticks++
      sleep --ms=2
  try:
    expect-throw "firmware: incomplete image":
      stage "truncated" size 4097 checksum
    expect-throw "INVALID_STATE": firmware.upgrade
    print "firmware-stream-rp2040: REJECTED truncated"
    expect-throw "firmware: checksum mismatch":
      stage "corrupt" size size checksum
    expect-throw "INVALID_STATE": firmware.upgrade
    print "firmware-stream-rp2040: REJECTED corrupt"

    // Store the verifier's expectations before publishing a committed image.
    state := storage.Bucket.open --flash STATE
    try:
      state["expected"] = checksum
      state["before"] = before
      state["rejected"] = 2
    finally:
      state.close
    stage "valid" size size checksum
    expect (ticks > 100)
  finally:
    collector.cancel
  print "firmware-stream-rp2040: COMMITTED"
  firmware.upgrade

stage name/string size/int limit/int checksum/ByteArray:
  writer := firmware.FirmwareWriter 0 size
  try:
    print "firmware-stream-rp2040: READY $name"
    received := 0
    while received < limit:
      count := min 1024 (limit - received)
      bytes := with-timeout --ms=30_000: stdio.stdin.read-bytes count
      writer.write bytes
      // Neither the service nor its worker may retain a mutable heap pointer.
      bytes.fill 0
      received += count
      print "firmware-stream-rp2040: ACK $name $received"
    writer.commit --checksum=checksum
  finally:
    writer.close
