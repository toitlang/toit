// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in tests/LICENSE.

import cli
import expect show *
import io
import uart
import ...esp-tester.tester as tester
import ...esp-tester.shared show *

// The expected base is supplied explicitly; never assume a deployed identity.

// Run under the rig lock from the repository root. Arguments: compiler,
// EC port, S3 port, rate, width, external-memory flag, SPI mode, stall ms,
// buffer duration (default or 100), and expected base identity.
main args:
  expect (args.size == 10)
  expected-base := args[9]
  expect (expected-base.starts-with "base-v")
  stall-ms := int.parse args[7]
  expect (stall-ms == 0 or stall-ms == 100)
  duration := args[8]
  expect (["default", "100"].contains duration)
  duration-label := duration == "default" ? "" : " buffer_ms=$duration"
  rate := int.parse args[3]
  bits := int.parse args[4]
  expect (0 < rate <= 96_000)
  expect ([16, 24, 32].contains bits)
  expect (bits != 32 or rate <= 48_000)
  external := int.parse args[5]
  expect (external == 0 or external == 1)
  spi-mode := int.parse args[6]
  expect (0 <= spi-mode <= 1)
  ui := cli.Ui.plain
  tester.start-time-us = Time.monotonic-us
  tester.with-tmp-dir: |directory/string|
    image := tester.compile-test-image args[0]
        "tests/hw/ec618/i2s-duplex-ec618.toit"
        --tmp-dir=directory
        --ui=ui
    preflight := tester.compile-test-image args[0]
        "tests/hw/ec618/rig-preflight-ec618.toit"
        --tmp-dir=directory
        --ui=ui
    ec := tester.Ec618Link --port-path=args[1] --fast-baud=115200
    peer := uart.HostPort args[2] --baud-rate=115200
    running := false
    try:
      failure := catch:
        health ec preflight expected-base
        exchange peer "PING" "EC618-CONTINUOUS-SPI-v3"
        exchange peer "STOP" "OK"
        exchange peer "SELFTEST $spi-mode" "SELFTEST-PASS"
        exchange peer "PREPARE $rate $bits $external $spi-mode" "READY"
        exchange peer "STALL $stall-ms" "OK"
        ec.send-arg "$rate,$bits,0,master,0,duplex,$duration,10"
        ec.install-container image
        pending := ""
        started := false
        passed := false
        running = true
        success := ec.run --timeout-ms=30_000 --on-output=(:: |text/string|
          pending += text
          while true:
            newline := pending.index-of "\n"
            if newline < 0: break
            line := pending[..newline].trim
            pending = pending[newline + 1..]
            if line == "I2S DUPLEX READY master=true rate=$rate bits=$bits format=0 slots=0$duration-label capture_s=10":
              if started: throw "Duplicate EC618 ready"
              exchange peer "START" "READY"
              started = true
            if line == "I2S DUPLEX PASS master=true rate=$rate bits=$bits format=0 slots=0$duration-label capture_s=10 errors=0":
              if not started: throw "EC618 verdict before start"
              passed = true
          if pending.size > 8192: throw "Oversized EC618 output line")
        running = false
        exchange peer "RESULT" "VERIFIED"
        if not success or not passed: throw "Missing clean EC618 duplex verdict"
        print "DUAL NATIVE PASS rate=$rate bits=$bits"
      cancel-error := catch:
        if running:
          ec.send CMD-CANCEL
          ec.expect "CANCEL" ACK-OK --timeout-ms=3000
      stop-error := catch: exchange peer "STOP" "OK"
      health-error := catch: health ec preflight expected-base
      if cancel-error: print "SPI observer EC cleanup failed: $cancel-error"
      if stop-error: print "SPI observer peer cleanup failed: $stop-error"
      if health-error: print "SPI observer final health failed: $health-error"
      if failure: throw failure
      if cancel-error: throw cancel-error
      if stop-error: throw stop-error
      if health-error: throw health-error
    finally:
      peer.close
      ec.close

exchange peer/uart.HostPort command/string expected/string?:
  peer.out.write "$command\n" --flush
  with-timeout --ms=30000:
    while true:
      line := boot-line peer.in
      if not line.starts-with "DUAL-REPLY ": continue
      if expected and line != "DUAL-REPLY $expected": throw "Unexpected observer reply: $line"
      if not expected and not line.starts-with "DUAL-REPLY OBSERVATION ":
        throw "Missing observer metadata: $line"
      return

// USB-UART reset/baud transitions can leave malformed boot chatter. Keep
// capture data strict, but consume startup lines without UTF-8 assumptions.
boot-line input/io.Reader -> string:
  newline := input.index-of '\n'
  if newline < 0: throw "SPI observer disconnected"
  if newline > 4096: throw "Oversized SPI observer startup line"
  line := (input.read-bytes newline).to-string-non-throwing.trim
  input.skip 1
  print "SPI console: $line"
  return line

health ec/tester.Ec618Link image/ByteArray expected-base/string:
  ec.handshake --attempts=3
  ec.send-arg expected-base
  ec.install-container image
  if not (ec.run --timeout-ms=30_000): throw "EC618 health failed"
