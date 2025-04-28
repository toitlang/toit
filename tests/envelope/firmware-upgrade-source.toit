// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.firmware
import host.file
import host.os

main:
  new-firmware-path := os.env["TOIT_FIRMWARE_TEST_PATH"]
  print "Updating firmware with $new-firmware-path"
  firmware-bytes := file.read-contents new-firmware-path
  writer := firmware.FirmwareWriter 0 firmware-bytes.size
  writer.write firmware-bytes
  writer.commit
  firmware.upgrade
