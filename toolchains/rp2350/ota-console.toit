// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import encoding.hex
import io show Reader
import io.stdio
import system.firmware

/** USB bring-up transport for the standard Toit firmware service. */
class UpdateConsole:
  input_/Reader := stdio.stdin

  run -> none:
    while true:
      error := catch:
        command := read-command_
        if not command.starts-with "TOIT-OTA ": continue
        parts := command.split " "
        if parts == ["TOIT-OTA", "INFO"]:
          trial := firmware.is-validation-pending ? 1 : 0
          print "TOIT-OTA INFO 1 $boot-partition $trial $slot-size_"
        else if parts.size == 4 and parts[1] == "WRITE":
          receive_ (int.parse parts[2]) (hex.decode parts[3])
        else if parts == ["TOIT-OTA", "REBOOT"]:
          print "TOIT-OTA REBOOTING"
          firmware.upgrade
        else if parts == ["TOIT-OTA", "VALIDATE"]:
          firmware.validate
          print "TOIT-OTA VALIDATED $boot-partition"
        else if parts == ["TOIT-OTA", "ROLLBACK"]:
          firmware.rollback
        else:
          throw "INVALID_ARGUMENT"
      if error:
        print "TOIT-OTA ERROR $error"
        input_.clear

  read-command_ -> string:
    line := #[]
    overflow := false
    while true:
      byte := input_.read-byte
      if byte == '\n':
        return overflow ? "" : line.to-string-non-throwing.trim
      if line.size < 160:
        line += #[byte]
      else:
        overflow = true

  receive_ size/int checksum/ByteArray -> none:
    if checksum.size != 32: throw "INVALID_ARGUMENT"
    writer := firmware.FirmwareWriter 0 size
    try:
      print "TOIT-OTA READY 4096"
      received := 0
      while received < size:
        count := min 4096 (size - received)
        bytes := with-timeout --ms=10_000: input_.read-bytes count
        writer.write bytes
        received += count
        print "TOIT-OTA ACK $received"
      writer.commit --checksum=checksum
      print "TOIT-OTA COMMITTED"
    finally:
      writer.close

boot-partition -> int:
  #primitive.rp2350.boot-partition

slot-size_ -> int:
  #primitive.rp2350.inactive-size
