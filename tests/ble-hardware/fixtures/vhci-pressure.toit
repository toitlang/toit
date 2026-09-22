// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import io
import system

// This probe deliberately leaves the native receive queue undrained. It uses
// direct commands so the ordinary HCI reader cannot consume packets for it.
main:
  2.repeat: | cycle/int |
    radio := esp32.Esp32Transport
    try:
      initial := radio.diagnostics
      if not initial or initial.capacity != 8 or initial.scan-drops != 0:
        throw "QUEUE_DIAGNOSTICS_INITIAL"
      command radio 0x0c03 #[]
      command radio 0x0c01 #[0, 0, 0, 0, 0, 0, 0, 0x20]
      command radio 0x2001 #[2, 0, 0, 0, 0, 0, 0, 0]
      command radio 0x200b #[0, 0x10, 0, 0x10, 0, 0, 0]
      command radio 0x200c #[1, 0]
      sleep --ms=3_000
      system.process-stats --gc
      pressure := radio.diagnostics
      if pressure.queued != 6 or pressure.high-water != 6 or pressure.scan-drops == 0 or pressure.fault:
        throw "QUEUE_PRESSURE_MISSING"
      // Six advertising events leave room for the command completion. Do not
      // drain until the controller has had time to deliver that completion.
      radio.send #[1, 0x0c, 0x20, 2, 0, 0]
      sleep --ms=100
      stopped := radio.diagnostics
      if stopped.queued != 7 or stopped.high-water != 7 or stopped.fault:
        throw "QUEUE_RESERVED_SLOT_FAILED"
      completion radio 0x200c
      drained := radio.diagnostics
      if drained.queued != 0 or drained.fault: throw "QUEUE_DRAIN_FAILED"
      // Samples own their bytes and are unchanged by subsequent queue activity.
      if pressure.queued != 6 or pressure.high-water != 6: throw "QUEUE_SAMPLE_CHANGED"
      command radio 0x1009 #[]
      print "VHCI_PRESSURE cycle=$cycle drops=$(drained.scan-drops) high-water=$(drained.high-water) drained=$(drained.queued) control=true"
    finally:
      radio.close
  print "VHCI_PRESSURE COMPLETE cycles=2"

command radio/esp32.Esp32Transport opcode/int parameters/ByteArray -> none:
  header := #[1, opcode & 0xff, opcode >> 8, parameters.size]
  radio.send (header + parameters)
  completion radio opcode

completion radio/esp32.Esp32Transport opcode/int -> none:
  with-timeout --ms=3_000:
    while true:
      packet := radio.receive
      if packet.size >= 4 and packet[0] == 4 and packet[1] == 0x3e and packet[3] == 2:
        continue
      if packet.size < 7 or packet[0] != 4 or packet[1] != 0x0e:
        throw "UNEXPECTED_HCI_EVENT"
      if (io.LITTLE-ENDIAN.uint16 packet 4) != opcode or packet[6] != 0:
        throw "HCI_COMMAND_FAILED"
      return
