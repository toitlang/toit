// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import device
import expect show *
import gpio
import rp2040
import rp2040.pio
import system
import uuid

// Run with lifecycle.py. This image resets repeatedly until the host requests
// recovery. No rig GPIO is driven; a stalled PIO DMA tests resource teardown.
main:
  expect-equals "rp2040" system.architecture
  id := rp2040.unique-id
  expect-equals 8 id.size
  expect-equals (uuid.Uuid.uuid5 "hw_id" id) device.hardware-id
  expect-equals device.hardware-id.stringify device.name
  expected := id.copy
  id[0] ^= 0xff
  system.process-stats --gc
  expect-equals expected rp2040.unique-id
  [23, 24, 29].do: |pin/int|
    expect-throw "RESTRICTED_PIN": gpio.Pin pin --input
  hex := (List expected.size: expected[it]).join "": "$(%02X it)"
  print "platform-rp2040: identity=$hex PASS"

  // PULL never completes without TX data, leaving RX DMA waiting at reset.
  machine := pio.StateMachine (pio.Program [0x80a0])
  machine.start
  transfer := machine.submit-read (ByteArray.external 256) --no-copy
  task:: transfer.wait
  sleep --ms=5000
  print "platform-rp2040: resetting with active DMA"
  rp2040.reset
  unreachable
