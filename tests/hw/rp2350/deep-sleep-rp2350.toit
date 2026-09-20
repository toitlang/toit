// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

import expect show *
import gpio
import rp2350
import rp2350.watchdog
import spi
import system.firmware
import system.storage
import uart

/**
Tests timed power-down, storage persistence, and peripheral teardown.

Supply a fresh `sleep-token` in the envelope config and leave the ESP32 rig
  pins as inputs. The test sleeps three times by default (`sleep-cycles` can
  increase this), then performs software and watchdog resets.
  Set `reject-trial` to check that sleep cannot bypass OTA trial validation.
*/

main:
  if firmware.config["reject-trial"]:
    expect firmware.is-validation-pending
    expect-throw "INVALID_STATE": rp2350.deep-sleep (Duration --s=2)
    expect firmware.is-validation-pending
    print "deep-sleep-rp2350: trial sleep rejected; requesting rollback"
    rp2350.reset
    unreachable

  token/string := firmware.config["sleep-token"]
  cycles/int := firmware.config["sleep-cycles"] or 3
  expect 3 <= cycles <= 100
  finished := cycles + 2
  bucket := storage.Bucket.open --flash "toit-rp2350-test/deep-sleep"
  ram := storage.Bucket.open --ram "toit-rp2350-test/deep-sleep"
  phase := 0
  try:
    if (bucket.get "token") == token: phase = bucket["phase"]
    if phase == 0 or phase > cycles:
      expect (not rp2350.woke-from-deep-sleep)
      expect-null (ram.get "token")
      if phase == 0: set-test-clock 1_700_000_000 0
      else: expect Time.now.s-since-epoch < 60
    else:
      expect rp2350.woke-from-deep-sleep
      expect-equals "survived power-down" bucket["payload"]
      expect-equals token ram["token"]
      expect-equals phase ram["phase"]
      elapsed := Time.monotonic-us - ram["monotonic"]
      minimum := (max 1_000 (sleep-duration (phase - 1))) * 1_000
      expect elapsed >= minimum
      expect elapsed < minimum + 15_000_000
      expect (Time.monotonic-us --since-wakeup) < elapsed
      wall-elapsed := Time.now.s-since-epoch - ram["wall"]
      expect wall-elapsed >= minimum / 1_000_000
      expect wall-elapsed < minimum / 1_000_000 + 15
      print "deep-sleep-rp2350: retained RAM and monotonic clock PASS elapsed-us=$elapsed"
    expect-equals (phase == finished) watchdog.caused-reset
    // Persist the next phase before deliberately losing RAM and restarting.
    bucket["token"] = token
    bucket["payload"] = "survived power-down"
    bucket["phase"] = phase < finished ? phase + 1 : finished
    if phase < cycles:
      ram["token"] = token
      ram["phase"] = phase + 1
      ram["monotonic"] = Time.monotonic-us
      ram["wall"] = Time.now.s-since-epoch
    else if phase == cycles + 1:
      // This must be erased by the upcoming watchdog reset, despite the
      // power manager's stale deep-sleep reset flag.
      ram["token"] = "watchdog-marker"
  finally:
    ram.close
    bucket.close

  firmware.validate
  print "deep-sleep-rp2350: phase=$phase sleep-wakeup=$(rp2350.woke-from-deep-sleep)"
  if phase == finished:
    print "deep-sleep-rp2350: PASS $cycles timer wakes, retained RAM/flash/clocks, software and watchdog resets"
    return
  if phase == cycles:
    // Neither a stale alarm nor the previous wake latch may affect this reset.
    print "deep-sleep-rp2350: requesting software reset after timer wakes"
    rp2350.reset
    unreachable
  if phase == cycles + 1:
    print "deep-sleep-rp2350: requesting watchdog reset after timer wakes"
    watchdog.watchdog-start --timeout=(Duration --s=1)
    sleep --ms=5000
    throw "watchdog failed to reset the chip"

  // Exercise resource teardown while UART is blocked and SPI is active.
  port := uart.Port --tx=16 --rx=1 --baud-rate=115_200
  pin := gpio.Pin 32 --input --pull-down
  bus := spi.Bus --mosi=7 --miso=4 --clock=6
  target := bus.device --cs=5 --frequency=3_000
  task:: target.write (ByteArray 512 --initial=0xa5)
  task:: port.in.read-byte
  sleep --ms=50
  expect-equals 0 pin.get
  milliseconds := sleep-duration phase
  // The one-second application watchdog must stop during the longer sleep.
  watchdog.watchdog-start --timeout=(Duration --s=1)
  print "deep-sleep-rp2350: entering sleep duration-ms=$milliseconds with active peripherals"
  rp2350.deep-sleep (Duration --ms=milliseconds)
  unreachable

set-test-clock seconds/int nanoseconds/int -> none:
  #primitive.core.set-real-time-clock

sleep-duration phase/int -> int:
  if phase == 0: return 0
  if phase == 1: return 2_000
  if phase == 2: return 5_000
  return 1_000
