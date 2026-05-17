// Tests OTA commit on EC618.
//
// Reads the current firmware via firmware.map and writes it back through
// the OTA primitives. This is a no-op update that exercises the full
// OTA path: write to FOTA, SHA-256 verification, and copy back to the
// active image region.
//
// After the commit the device reboots. On the second boot the test
// detects (via a storage flag) that the OTA already ran and prints
// success.

import system.firmware
import system.storage

BUCKET-NAME ::= "test/ota"
FLAG-KEY ::= "ota-done"

main:
  // Heartbeat task to detect freezes.
  task::
    while true:
      print "[heartbeat] alive"
      sleep --ms=2000

  bucket := storage.Bucket.open --flash BUCKET-NAME
  try:
    if bucket.get FLAG-KEY:
      // Second boot after OTA commit.
      bucket.remove FLAG-KEY
      print "OTA TEST PASSED"
      return

    // First boot: set the flag before triggering OTA so we can
    // detect the reboot.
    bucket[FLAG-KEY] = #[1]

    print "Reading current firmware..."
    firmware.map: | mapping/firmware.FirmwareMapping |
      size := mapping.size
      print "Firmware size: $size bytes"

      writer := firmware.FirmwareWriter 0 size
      written := 0
      chunk-size := 4096
      while written < size:
        remaining := size - written
        n := remaining < chunk-size ? remaining : chunk-size
        bytes := ByteArray n
        mapping.copy written (written + n) --into=bytes
        writer.write bytes
        written += n

      print "Committing OTA (will reboot)..."
      writer.commit
      firmware.upgrade
      // Should not reach here.
      print "ERROR: firmware.upgrade returned!"
  finally: | is-exception _ |
    if is-exception:
      // Clean up on failure so the test can be retried.
      bucket.remove FLAG-KEY
    bucket.close
