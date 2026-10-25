// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import gpio
import zephyr
import zephyr.watchdog
import system.storage
import expect show *
import .storage-nrf5340 show verify-persistent

main:
  ack := gpio.Pin 33 --input --pull-down
  phase-pins := [32, 36].map: gpio.Pin it --input
  phase := phase-pins[0].get | phase-pins[1].get << 1
  phase-pins.do: it.close
  sleep --ms=100
  sequence := 0
  request := : | command/string |
    sequence++
    print "GPIO REQUEST $sequence $command"
    with-timeout --ms=5000: ack.wait-for (sequence & 1)
  watchdog.watchdog-stop
  // This test follows storage-nrf5340 and verifies preservation when flashing
  // a different firmware image, as well as preservation across fault resets.
  verify-persistent
  if phase == 0:
    storage.Region.delete --flash "nrf-recovery"
  region := storage.Region.open --flash "nrf-recovery" --capacity=4096
  if phase != 0:
    expect (zephyr.reset-reason & zephyr.RESET-WATCHDOG != 0)
    expected := phase == 1 ? 0xfe : 0xfc
    expect-bytes-equal (ByteArray 4096 --initial=expected) (region.read --from=0 --to=4096)
    print "STORAGE interrupted rewrite phase=$phase recovered value=$expected PASS"
  if phase == 3:
    region.close
    storage.Region.delete --flash "nrf-recovery"
    indicator := gpio.Pin 8 --output --value=1
    request.call "WAIT 18 1"
    print "NRF5340 STORAGE RECOVERY PASS"
    return

  region.erase
  region.write --at=0 (ByteArray 4096 --initial=0xfe)
  if phase == 0:
    start := Time.monotonic-us
    region.write --at=0 (ByteArray 4096 --initial=0xfc)
    print "STORAGE dense page rewrite took $((Time.monotonic-us - start) / 1000) ms"
    region.erase
    region.write --at=0 (ByteArray 4096 --initial=0xfe)
  next := phase + 1
  request.call "CONFIG 13 OUT $(next & 1)"
  request.call "CONFIG 32 OUT $((next >> 1) & 1)"
  // Timings deliberately target staging, destination erase and descriptor
  // retirement on this board. The runner also requires a recovery log entry.
  milliseconds := [100, 250, 400][phase]
  update := ByteArray 4096 --initial=0xfc
  print "STORAGE interrupting rewrite after $milliseconds ms"
  watchdog.watchdog-start --timeout=(Duration --ms=milliseconds)
  region.write --at=0 update
  // If the rewrite completed before the reset, do not silently pass.
  watchdog.watchdog-stop
  throw "rewrite completed before the fault injection"
