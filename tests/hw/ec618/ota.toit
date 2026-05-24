// Exercises the EC618 OTA path end-to-end.
//
// The test reads the currently running firmware via firmware.map, writes it
// back through the OTA primitives, and triggers a reboot. The image is
// unchanged, so a successful round-trip means the SHA-256 check at ota_end
// passed and the post-shutdown copy from FOTA into the active image area
// completed without bricking the device.
//
// First boot: stage the OTA, set the flag, reboot via firmware.upgrade.
// Second boot: see the flag, clear it, declare success.
//
// The flag is set ONLY after writer.commit succeeds and immediately before
// the call to firmware.upgrade. If we crash earlier, the flag is not
// persisted, so a stale flag from a prior boot can't be mistaken for an
// actual OTA event.
//
// IMPORTANT: this test can only see the storage flag, not whether the
// FOTA->AP copy actually succeeded. The C++ side prints
//   [toit] INFO: OTA commit complete -- rebooting
// on success and
//   [toit] ERROR: OTA commit failed -- active image may be corrupt
// on failure. The Toit-level "OTA TEST PASSED" message is only meaningful
// in combination with seeing the C++ success line in the previous boot's
// log.

import system.firmware
import system.storage

// The bucket name carries a version suffix so a stale flag persisted in LFS
// by an earlier buggy test binpkg can't be mistaken for an OTA event in
// this run. Bump the suffix when re-running after a structural change.
BUCKET-NAME ::= "test/ota-4"
FLAG-KEY    ::= "ota-done"

main:
  task::
    while true:
      print "[heartbeat] alive"
      sleep --ms=2000

  bucket := storage.Bucket.open --flash BUCKET-NAME
  try:
    if bucket.get FLAG-KEY:
      bucket.remove FLAG-KEY
      print "[ota-test] SECOND BOOT — OTA commit observed"
      print "OTA TEST PASSED"
      return

    print "[ota-test] FIRST BOOT — staging OTA"

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

      print "Committing OTA..."
      writer.commit

      // Past the point where the OTA is staged and verified. Set the flag
      // now so that a successful reboot into the new image is the only way
      // to observe FLAG-KEY on the next boot.
      bucket[FLAG-KEY] = #[1]
      print "[ota-test] Flag set; calling firmware.upgrade (reboot)..."
      firmware.upgrade
      throw "firmware.upgrade returned unexpectedly"
  finally:
    bucket.close
