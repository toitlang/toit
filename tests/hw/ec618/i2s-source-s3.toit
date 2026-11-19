// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import i2s
import gpio
import monitor
import uart
import ..shared.i2s-pattern
import .wiring show *

// Requires the DS18B20 data lead to be disconnected from S3 GPIO1 first.
// GPIO1 -> EC618 PAD19 BCLK; GPIO2 -> PAD20 WS; GPIO41 -> PAD21 DIN.
main:
  bus/i2s.Bus? := null
  go/gpio.Pin? := null
  worker/Task? := null
  done/monitor.Latch? := null
  prepared/string? := null
  data/ByteArray? := null
  offset := 0
  console := uart.Port.console
  try:
    while line := console.in.read-line:
      parts := line.split " "
      if parts[0] == "PING":
        print "BUS-REPLY READY"
      else if parts[0] == "IDENTIFY":
        print "BUS-REPLY EC618-I2S-SOURCE-v1"
      else if parts[0] == "START" or parts[0] == "PREPARE":
        if worker: throw "ALREADY_IN_USE"
        configuration := parts[1..].join " "
        if prepared != null and prepared != configuration: throw "INVALID_ARGUMENT"
        if not bus:
          rate := int.parse parts[1]
          bits := int.parse parts[2]
          format := int.parse parts[3]
          // START rate bits format slave waits for EC618-generated clocks.
          if parts.size > 4 and parts[4] != "master" and parts[4] != "slave":
            throw "INVALID_ARGUMENT"
          master := parts.size <= 4 or parts[4] != "slave"
          if not master: go = gpio.Pin S3-I2S-PEER-READY-PIN --output --value=0
          data = pattern bits
          bus = i2s.Bus --master=master --tx=S3-I2S1-TX-PIN
              --sck=S3-I2S1-SCK-PIN
              --ws=S3-I2S1-WS-PIN
          bus.configure --sample-rate=rate --bits-per-sample=bits --format=format
              --slots=i2s.Bus.SLOTS-STEREO-BOTH
          // ESP32-S3 MSB mode emits a half-width first data pulse at clock
          // startup. Counted zero training frames keep the initial bit at idle
          // level while the receiver acquires frame synchronization.
          preamble := ByteArray (TRAINING-FRAMES * bits / 8 * 2)
          if (bus.preload preamble) != preamble.size: throw "Short preamble preload"
          offset = 0
          while true:
            n := bus.preload data[offset..]
            if n == 0: break
            if n % (bits / 8 * 2) != 0: throw "Partial I2S preload frame"
            offset = (offset + n) % data.size
          prepared = configuration
        if parts[0] == "PREPARE":
          print "BUS-REPLY READY"
          continue
        bus.start
        done = monitor.Latch
        worker = task::
          try:
            // Continue from the exact point where preload filled the DMA
            // buffers, including a partially preloaded pattern cycle.
            if offset != 0: bus.write data[offset..]
            while true: bus.write data
          finally:
            critical-do --no-respect-deadline: done.set true
        if go: go.set 1
        print "BUS-REPLY READY"
      else if parts[0] == "STOP":
        if worker:
          worker.cancel
          with-timeout --ms=2000: done.get
          worker = null
        if bus:
          bus.close
          bus = null
          prepared = null
          data = null
        if go:
          go.set 0
          go.close
          go = null
        print "BUS-REPLY OK"
      else:
        throw "Unknown command: $line"
  finally:
    if worker:
      worker.cancel
      with-timeout --ms=2000: done.get
    if bus: bus.close
    if go: go.close
