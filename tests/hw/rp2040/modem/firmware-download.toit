// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import http
import io
import net
import system
import system.assets
import system.containers
import system.firmware
import system.storage
import .firmware-common show STATE current-digest
import .network-service show open-service
import .service-containers show image

main:
  expected/ByteArray := assets.decode["sha256"]
  size := int.parse assets.decode["size"].to-string
  provider := containers.start (image "net-provider")
  service := open-service
  network := net.open --service=service
  ticks := 0
  collector := task::
    while true:
      ticks++
      system.process-stats --gc
      sleep --ms=20
  try:
    // A short body must not commit partial firmware. The following complete
    // download verifies ownership was released after the failed transfer.
    error := catch: download network "/truncated.bin" size expected
    expect-equals io.Reader.UNEXPECTED-END-OF-READER error
    expect-equals "INVALID_STATE" (catch: firmware.upgrade)
    print "RP2040 WiFi firmware: rejected truncated download"
    error = catch: download network "/corrupt.bin" size expected
    expect-equals "firmware: checksum mismatch" error
    expect-equals "INVALID_STATE" (catch: firmware.upgrade)
    print "RP2040 WiFi firmware: rejected bad checksum"
    download network "/firmware.bin" size expected
    expect (ticks > 100)
    state := storage.Bucket.open --flash STATE
    try:
      state["expected"] = expected
      state["before"] = current-digest
      state["rejected"] = 2
    finally:
      state.close
  finally:
    collector.cancel
    network.close
    service.close
    provider.stop
    provider.close
  print "RP2040 WiFi firmware: committed; upgrading"
  firmware.upgrade

download network/net.Interface path/string size/int checksum/ByteArray:
  client := http.Client network
  writer/firmware.FirmwareWriter? := null
  received := 0
  started := Time.monotonic-us
  try:
    with-timeout --ms=300_000:
      response := client.get "200.200.200.1" --port=4245 path
      expect-equals 200 response.status-code
      expect-equals size response.content-length
      writer = firmware.FirmwareWriter 0 size
      while bytes := response.body.read --max-size=1024:
        received += bytes.size
        writer.write bytes
      expect-equals size received
      writer.commit --checksum=checksum
  finally:
    print "RP2040 WiFi firmware $path: received $received/$size bytes in $((Time.monotonic-us - started) / 1000) ms"
    if writer: writer.close
    client.close
