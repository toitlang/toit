// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import crypto.sha256 show Sha256
import system
import system.firmware
import system.storage

main:
  expect (not firmware.is-validation-pending)
  expect (not firmware.is-rollback-possible)
  expect (not firmware.validate)
  expect-equals "UNSUPPORTED" (catch: firmware.rollback)
  expect-equals "INVALID_STATE" (catch: firmware.upgrade)
  expect-equals null firmware.config["missing-test-key"]
  bucket := storage.Bucket.open --flash "toit-rp2040-test/firmware"
  firmware.map: |mapping/firmware.FirmwareMapping|
    expect (mapping.size >= 264)
    hash := Sha256
    for from := 0; from < mapping.size; from += 1024:
      count := min 1024 (mapping.size - from)
      data := ByteArray count
      mapping.copy from (from + count) --into=data
      hash.add data
    digest := hash.get
    if previous := bucket.get "committed":
      expect-equals digest previous
      bucket.remove "committed"
      bucket.close
      print "firmware-rp2040: PASS upgraded through the firmware service"
      return

    expect-equals "INVALID_ARGUMENT" (catch: firmware.FirmwareWriter 1 4096)
    expect-equals "INVALID_ARGUMENT" (catch: firmware.FirmwareWriter 0 0xf0001)
    writer := firmware.FirmwareWriter 0 264
    expect-equals "ALREADY_IN_USE" (catch: firmware.FirmwareWriter 0 264)
    expect-equals "firmware: incomplete image" (catch: writer.commit)
    writer.pad 264 --value=0
    expect-equals "firmware: checksum mismatch" (catch: writer.commit --checksum=#[0])
    writer.close
    writer = firmware.FirmwareWriter 0 264
    writer.pad 264 --value=0
    expect-equals "firmware: flash operation failed" (catch: writer.commit)
    writer.close
    expect-equals "INVALID_STATE" (catch: firmware.upgrade)

    // Terminate a client while its provider is still staging a multi-sector
    // pad. The service must finish the copied sector and release ownership.
    state := storage.Bucket.open --ram "toit-rp2040-test/firmware-client"
    state.remove "started"
    state.remove "completed"
    child := spawn::
      abandoned := firmware.FirmwareWriter 0 65536
      child-state := storage.Bucket.open --ram "toit-rp2040-test/firmware-client"
      child-state["started"] = true
      task::
        sleep --ms=5
        exit 0
      yield
      abandoned.pad 65536
      child-state["completed"] = true
    with-timeout --ms=5000:
      while not (state.get "started"): sleep --ms=1
      while not (catch: child.priority): sleep --ms=1
    expect-equals null (state.get "completed")
    state.close

    ticks := 0
    done := false
    task::
      while not done:
        ticks++
        sleep --ms=5
    with-timeout --ms=5000:
      while true:
        error := catch: writer = firmware.FirmwareWriter 0 mapping.size
        if not error: break
        expect-equals "ALREADY_IN_USE" error
        sleep --ms=1
    try:
      for from := 0; from < mapping.size; from += 1024:
        count := min 1024 (mapping.size - from)
        data := ByteArray count
        mapping.copy from (from + count) --into=data
        writer.write data
        if from % 16384 == 0: system.process-stats --gc
      writer.commit --checksum=digest
    finally:
      writer.close
      done = true
    expect (ticks > 10)
    bucket["committed"] = digest
    bucket.close
    print "firmware-rp2040: committed; upgrading"
    firmware.upgrade
