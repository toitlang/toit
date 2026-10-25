// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import io
import monitor show Semaphore
import uart

main:
  // Each child is the sole stdin owner. Its exit must release the callback and
  // native ring, allowing the next container to acquire the console again.
  16.repeat: |cycle|
    child := spawn::
      check-input "child-$cycle" (257 + cycle) cycle
    with-timeout --ms=5000:
      while not (catch: child.priority): sleep --ms=1

  input := io.stdin
  ticks := 0
  ticker := task::
    while true:
      ticks++
      sleep --ms=1
  before := ticks
  expect-equals DEADLINE-EXCEEDED-ERROR (catch:
    with-timeout --ms=100: input.read-byte)
  expect (ticks > before + 10)
  finished := Semaphore
  reader := task::
    try:
      input.read-byte
      unreachable
    finally:
      critical-do: finished.up
  sleep --ms=30
  reader.cancel
  with-timeout --ms=1000: finished.down
  check-input "after-cancel" 256 83
  print "STDIN cancellation and scheduler PASS"

  [1, 255, 1023, 1024, 1025, 4095, 4096, 4097, 16385].do: |size|
    check-input "binary-$size" size 197
  ticker.cancel

  // Both UARTE instances must work together, with separate DMA buffers and
  // byte-counting timers. The ESP32 echoes the application UART concurrently.
  print "STDIN UART OPEN"
  expect-equals 0xac (with-timeout --ms=5000: input.read-byte)
  port := uart.Port --tx=36 --rx=37 --baud-rate=115200
  uart-done := Semaphore
  uart-error := null
  task::
    uart-error = catch:
      32.repeat: |cycle|
        data := ByteArray 256: (it + cycle) & 0xff
        port.out.write data --flush
        received := 0
        while received < data.size:
          chunk := port.in.read
          expect (received + chunk.size <= data.size)
          chunk.size.repeat: |index|
            expect-equals data[received + index] chunk[index]
          received += chunk.size
    uart-done.up
  check-input "binary-dual" 16_385 91
  with-timeout --ms=5000: uart-done.down
  expect-null uart-error
  expect-equals 0 port.errors
  port.close
  print "STDIN UART CLOSE"
  expect-equals 0xad (with-timeout --ms=5000: input.read-byte)
  print "STDIN concurrent UART PASS"

  // The parent keeps stdin open while two other containers share its queue.
  // The host waits for both READY markers before sending the two bytes.
  children := []
  2.repeat: |index|
    children.add (spawn::
      stream := io.stdin
      print "STDIN SHARED READY $index"
      value := with-timeout --ms=5000: stream.read-byte
      expect (value == 17 or value == 29)
      print "STDIN SHARED PASS $index $value")
  children.do: |child|
    with-timeout --ms=6000:
      while not (catch: child.priority): sleep --ms=1
  check-input "after-shared" 257 42

  print "STDIN OVERFLOW READY"
  sleep --ms=2000
  error := catch: with-timeout --ms=100: input.read-byte
  expect-not-null error
  expect (error != DEADLINE-EXCEEDED-ERROR)
  print "STDIN OVERFLOW PASS $error"
  check-input "after-overflow" 512 99
  print "NRF5340 STDIN PASS"
  // Leave a waiter alive when the process exits, exercising teardown while
  // the callback and notification resource are still installed.
  task:: input.read-byte
  sleep --ms=10
  exit 0

check-input label/string size/int seed/int:
  input := io.stdin
  print "STDIN REQUEST $label $size $seed"
  data := with-timeout --ms=5000: input.read-bytes size
  size.repeat: |index|
    expect-equals ((index * 73 + seed) & 0xff) data[index]
  print "STDIN DATA PASS $label"
