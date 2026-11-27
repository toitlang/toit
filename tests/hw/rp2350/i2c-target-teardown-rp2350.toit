// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show expect-equals
import i2c
import system.storage
import uart

BUCKET ::= "toit-rp2350-test/i2c-target-teardown"

/**
Process-teardown fixture for the RP2350 I2C target.

Run with i2c-target-controller-esp32.toit. A child process exits from inside a
  dynamic read handler while RD_REQ is stretching SCL. Its resource teardown
  must disable the peripheral and release SCL. The parent then recreates I2C0
  and completes another controller read in the same VM.
*/
main:
  bucket := storage.Bucket.open --ram BUCKET
  try:
    bucket.remove "armed"
    bucket.remove "entered-handler"
    print "i2c-target-teardown-rp2350: waiting 20 seconds for ESP32 peer"
    sleep --ms=20_000
    control := uart.Port --tx=16 --rx=1 --baud-rate=115_200
    try:
      control.out.write #[0x10, 0, 7, 0, 0x42]
      control.out.flush
      expect-equals 0x5a (with-timeout --ms=5_000: control.in.read-byte)

      child := spawn:: exit-while-stretched
      with-timeout --ms=5_000:
        while true:
          armed := false
          catch: armed = bucket["armed"]
          if armed: break
          sleep --ms=1

      // The parent owns the control UART, so the child's abrupt resource
      // teardown cannot inject a framing byte before the reuse check.
      control.out.write #[0x14, 0, 32]
      control.out.flush
      with-timeout --ms=10_000:
        while true:
          error := catch: child.priority
          if error:
            expect-equals "INVALID_ARGUMENT" error
            break
          sleep --ms=1
      expect-equals true bucket["entered-handler"]

      // Allow the ESP controller's bounded transaction to finish after target
      // teardown, then prove the released controller and pins work in this VM.
      sleep --ms=2_200
      target := i2c.Target
          --sda=4
          --scl=5
          --address=0x42
          --default-response=#[0xa6, 0x39]
          --pull-up
      try:
        control.out.write #[0x10, 0, 7, 0, 0x42]
        control.out.flush
        expect-equals 0x5a (with-timeout --ms=5_000: control.in.read-byte)
        control.out.write #[0x11, 0, 2]
        control.out.flush
        expect-equals 0x5a (with-timeout --ms=5_000: control.in.read-byte)
        expect-equals 0xa6 control.in.read-byte
        expect-equals 0x39 control.in.read-byte
        control.out.write #[0xff]
        control.out.flush
        expect-equals 0x5a control.in.read-byte
      finally:
        target.close
      print "i2c-target-teardown-rp2350: PASS child exit and same-VM reuse"
    finally:
      control.close
  finally:
    bucket.remove "armed"
    bucket.remove "entered-handler"
    bucket.close

exit-while-stretched -> none:
  bucket := storage.Bucket.open --ram BUCKET
  target := i2c.Target
      --sda=4
      --scl=5
      --address=0x42
      --pull-up
  bucket["armed"] = true
  target.serve-read-requests --response-timeout-us=1_000_000:
    // exit bypasses language-level finally blocks. ResourceGroup teardown must
    // disable target mode and release SCL while RD_REQ still holds it low.
    bucket["entered-handler"] = true
    print "i2c-target-teardown-rp2350: EXIT WHILE STRETCHED"
    exit 0
