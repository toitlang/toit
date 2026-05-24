// Exercises the EC618 OTA path end-to-end.
//
// The test reads the currently running firmware via firmware.map, writes it
// back through the OTA primitives, and triggers a reboot. The image is
// unchanged, so a successful round-trip means the SHA-256 check at ota_end
// passed and the post-shutdown copy from FOTA into the active image area
// completed without bricking the device.
//
// First boot: stage the OTA, set a flag, reboot.
// Second boot: see the flag, clear it, declare success.

import system.firmware
import system.storage

BUCKET-NAME ::= "test/ota"
FLAG-KEY    ::= "ota-done"

main:
  task::
    while true:
      print "[heartbeat] alive"
      sleep --ms=2000

  bucket := storage.Bucket.open --flash BUCKET-NAME
  cleanup-on-failure := true
  try:
    if bucket.get FLAG-KEY:
      bucket.remove FLAG-KEY
      cleanup-on-failure = false
      print "OTA TEST PASSED"
      return

    bucket[FLAG-KEY] = #[1]

    print "Reading current firmware..."
    firmware.map: | mapping/firmware.FirmwareMapping |
      size := mapping.size
      print "Firmware size: $size bytes"

      writer := firmware.FirmwareWriter 0 size
      chunk-size := 4096
      written := 0
      while written < size:
        remaining := size - written
        n := remaining < chunk-size ? remaining : chunk-size
        bytes := ByteArray n
        mapping.copy written (written + n) --into=bytes
        writer.write bytes
        written += n

      print "Committing OTA (will reboot)..."
      writer.commit
      cleanup-on-failure = false  // Past the point of no return.
      firmware.upgrade
      throw "firmware.upgrade returned unexpectedly"
  finally:
    if cleanup-on-failure:
      bucket.remove FLAG-KEY
    bucket.close
