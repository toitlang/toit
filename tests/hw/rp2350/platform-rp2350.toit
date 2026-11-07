// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

import device
import expect show *
import gpio
import rp2350
import spi
import system
import system.firmware
import system.storage
import uart
import uuid

/**
Tests chip identity and a software reset with live peripheral resources.

The envelope config supplies `expected-id` (the USB serial number) and a
  fresh `reset-token`. The flash bucket retains identity across one reset;
  subsequent boots with the same token check it without resetting again.
Setting `reject-trial` requests a reset before validation instead, to test
  rollback to the preceding confirmed firmware.
The ESP32 peer must leave the rig's GPIOs as inputs.
*/

main:
  id := rp2350.unique-id
  expect-equals 8 id.size
  hex := (List id.size: id[it]).join "": "$(%02X it)"
  expect-equals firmware.config["expected-id"] hex
  expect-equals (uuid.Uuid.uuid5 "hw_id" id) device.hardware-id
  expect-equals device.hardware-id.stringify device.name
  // The caller owns its returned byte array, not the SDK's cached identity.
  id[0] = id[0] ^ 0xff
  system.process-stats --gc
  expect-equals (id[0] ^ 0xff) rp2350.unique-id[0]
  id = rp2350.unique-id

  if firmware.config["reject-trial"]:
    print "platform-rp2350: resetting unconfirmed trial"
    reset-with-peripherals
    unreachable

  token/string := firmware.config["reset-token"]
  bucket := storage.Bucket.open --flash "toit-rp2350-test/platform"
  already-reset := false
  try:
    already-reset = (bucket.get "token") == token
    if already-reset:
      expect-equals id bucket["chip-id"]
      expect-equals device.name bucket["device-name"]
    else:
      bucket["chip-id"] = id
      bucket["device-name"] = device.name
      bucket["token"] = token
  finally:
    bucket.close

  firmware.validate
  print "platform-rp2350: chip=$hex device=$(device.name)"
  if already-reset:
    print "platform-rp2350: PASS identity survived software reset"
    return

  reset-with-peripherals
  unreachable

reset-with-peripherals -> none:
  // Reset must stop the blocked UART reader and the active SPI transaction,
  // then tear down the shared peripheral event task without hanging.
  port := uart.Port --tx=16 --rx=1 --baud-rate=115_200
  pin := gpio.Pin 32 --input --pull-down
  bus := spi.Bus --mosi=7 --miso=4 --clock=6
  target := bus.device --cs=5 --frequency=3_000
  started := false
  task::
    started = true
    target.write (ByteArray 512 --initial=0xa5)
  task:: port.in.read-byte
  sleep --ms=50
  expect started
  expect-equals 0 pin.get
  print "platform-rp2350: resetting with active peripherals"
  rp2350.reset
  unreachable
