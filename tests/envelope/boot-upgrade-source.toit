// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.firmware
import host.file
import host.os

import .exit-codes

main:
  new-firmware-path := os.env["TOIT_FIRMWARE_TEST_PATH"]
  if not file.is-file new-firmware-path:
    print "no firmware file found at $new-firmware-path"
    print "looks like a successful rollback"
    exit EXIT-CODE-STOP

  print "updating firmware with $new-firmware-path"
  firmware-bytes := file.read-contents new-firmware-path
  // Delete it, so that we don't loop forever if there is a rollback.
  file.delete new-firmware-path
  writer := firmware.FirmwareWriter 0 firmware-bytes.size
  writer.write firmware-bytes
  writer.commit
  firmware.upgrade
