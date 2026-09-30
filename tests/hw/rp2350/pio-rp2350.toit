// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import monitor
import rp2350.pio
import system
import .gpio-interrupt-rp2350 as gpio-test
import ...pio.programs show *

main:
  sleep --ms=1500
  print "pio-rp2350: starting"
  with-timeout --ms=30_000:
    echo-tests
    allocating-read-test
    heap-buffer-test
    pin-loopback-test
    cancellation-tests
    waiter-close-test
    concurrent-reclaim-test
    orphan-test
    allocation-tests
    irq-tests
    gpio-test.main
  print "pio-rp2350: PASS"

echo-tests:
  sm := pio.StateMachine ECHO-PROGRAM --frequency=1_000_000
  try:
    expect (sm.frequency > 999_000 and sm.frequency < 1_001_000)
    sm.start
    [4, 16, 2400, 32_768].do: |size/int|
      [true, false].do: |copy/bool|
        source := ByteArray.external size
        size.repeat: source[it] = (it * 37 + 11) & 255
        expected := source.copy
        destination := ByteArray.external size
        tx := sm.submit-write source --copy=copy
        rx := sm.submit-read destination --copy=copy
        // Collect repeatedly while native DMA owns its buffers.
        4.repeat:
          system.process-stats --gc
          sleep --ms=1
        tx.wait
        rx.wait
        expect-equals size tx.transferred
        expect-equals size rx.transferred
        returned-source := tx.take-buffer
        returned-destination := rx.take-buffer
        expect-equals expected returned-source
        expect-equals expected returned-destination
        if copy:
          expect-equals expected source
          expect-identical destination returned-destination
        else:
          expect-equals 0 source.size
          expect-equals 0 destination.size
          expect-not (identical returned-source source)
        expect-throw "ALREADY_CLOSED": tx.take-buffer
        tx.close
        rx.close
    // A slice falls back to a copy with --no-copy.
    source := #[1, 2, 3, 4, 5, 6, 7, 8]
    rx := sm.submit-read (ByteArray 4)
    sm.write source[4..] --no-copy
    expect-equals #[5, 6, 7, 8] rx.take-buffer
    expect-equals 8 source.size
    sm.pause
    sm.reset
  finally:
    sm.close
  print "pio-rp2350: echo, copy, ownership, GC PASS"

allocating-read-test:
  machine := pio.StateMachine ECHO-PROGRAM
  try:
    machine.start
    expected := #[1, 2, 3, 4, 128, 129, 254, 255]
    tx := machine.submit-write expected
    try:
      expect-equals expected (machine.read expected.size)
      tx.wait
    finally:
      tx.close
    machine.write-word 0xfedc_ba98
    expect-equals 0xfedc_ba98 machine.read-word
  finally:
    machine.close
  print "pio-rp2350: allocating reads and word I/O PASS"

heap-buffer-test:
  machine := pio.StateMachine ECHO-PROGRAM
  try:
    source := ByteArray 128: (it * 17 + 3) & 255
    expected := source.copy
    destination := ByteArray 128
    tx := machine.submit-write source --no-copy
    rx := machine.submit-read destination
    // TX stalls once its small FIFO fills. Both movable heap arrays must
    // remain safe while DMA retains native storage across collection.
    3.repeat: system.process-stats --gc
    machine.start
    tx.wait
    rx.wait
    expect-equals expected tx.take-buffer
    expect-equals expected rx.take-buffer
    expect-equals expected source
    expect-equals expected destination
  finally:
    machine.close
  print "pio-rp2350: movable heap buffers during GC PASS"

pin-loopback-test:
  sm := pio.StateMachine LOOPBACK-PROGRAM
      --frequency=5_000_000
      --in-pins=[34]
      --out-pins=[34]
      --output-pins=[34]
  try:
    source := ByteArray.external 4096
    source.size.repeat: source[it] = (it * 53 + 19) & 255
    expected := source.copy
    tx := sm.submit-write source --no-copy
    rx := sm.submit-read (ByteArray.external 4096) --no-copy
    sm.start
    tx.wait
    rx.wait
    expect-equals expected rx.take-buffer
    expect-equals expected tx.take-buffer
  finally:
    sm.close
  print "pio-rp2350: GP34 output/input loopback PASS"

cancellation-tests:
  sm := pio.StateMachine ECHO-PROGRAM
  try:
    buffer := ByteArray.external 4096
    rx := sm.submit-read buffer --no-copy
    rejected := ByteArray.external 4
    expect-throw "ALREADY_IN_USE": sm.submit-read rejected --no-copy
    expect-equals 4 rejected.size
    expect-throw "INVALID_STATE": sm.reset
    rx.cancel
    expect-throw "CANCELLED": rx.wait
    expect-equals 0 rx.transferred
    returned := rx.take-buffer
    expect-equals 4096 returned.size
    expect-equals (ByteArray 4096) returned
    sm.reset
    sm.start
    rx = sm.submit-read returned --no-copy
    sm.write #[1, 2, 3, 4]
    sleep --ms=2
    rx.cancel
    expect-throw "CANCELLED": rx.wait
    expect-equals 4 rx.transferred
    returned = rx.take-buffer
    expect-equals #[1, 2, 3, 4] returned[0..4]
    expect-equals (ByteArray 4092) returned[4..]
    sm.reset
    // Close a machine whose DMA is waiting indefinitely for RX data.
    rx = sm.submit-read (ByteArray.external 4096) --no-copy
    sm.close
    expect-throw "CLOSED": rx.wait
    rx.close
  finally:
    sm.close
  20.repeat:
    machine := pio.StateMachine ECHO-PROGRAM
    machine.submit-write (ByteArray.external 4096) --no-copy
    machine.start
    sleep --ms=1
    machine.close
    sleep --ms=1
  print "pio-rp2350: cancellation and close PASS"

waiter-close-test:
  machine := pio.StateMachine ECHO-PROGRAM
  transfer := machine.submit-read (ByteArray.external 4096) --no-copy
  ready := monitor.Latch
  done := monitor.Latch
  error := null
  task::
    ready.set true
    try:
      error = catch: transfer.wait
    finally:
      critical-do: done.set true
  ready.get
  sleep --ms=1
  machine.close
  with-timeout --ms=1000: done.get
  expect-equals "CLOSED" error
  transfer.close
  print "pio-rp2350: close wakes blocked waiter PASS"

concurrent-reclaim-test:
  machine := pio.StateMachine ECHO-PROGRAM
  transfer := machine.submit-read (ByteArray.external 4096) --no-copy
  ready := monitor.Latch
  reclaimed := monitor.Latch
  closed := monitor.Latch
  returned := null
  try:
    task::
      ready.set true
      try:
        returned = transfer.take-buffer
      finally:
        critical-do: reclaimed.set true
    ready.get
    sleep --ms=1
    // take-buffer holds the reclaim mutex while waiting for data. Closing
    // from another task must cancel DMA before trying to acquire that mutex.
    task::
      try:
        transfer.close
      finally:
        critical-do: closed.set true
    with-timeout --ms=1000:
      closed.get
      reclaimed.get
    expect-equals (ByteArray 4096) returned
    expect-throw "CANCELLED": transfer.wait
  finally:
    machine.close
  print "pio-rp2350: close interrupts pending reclamation PASS"

orphan-test:
  make-orphan
  3.repeat:
    system.process-stats --gc
    sleep --ms=5
  // The following full allocation test also checks that the orphan's state
  // machine, instruction memory and DMA buffer have been released.

make-orphan:
  machine := pio.StateMachine ECHO-PROGRAM
  machine.submit-read (ByteArray.external 4096) --no-copy
  machine.start

allocation-tests:
  // A full instruction memory image must be shared by four machines per PIO.
  instructions := List 32: 0xa042
  program := pio.Program instructions
  machines := []
  try:
    12.repeat:
      machines.add (pio.StateMachine program)
    expect-throw "ALREADY_IN_USE": pio.StateMachine program
  finally:
    machines.do: it.close
  // Only reserve inputs here: this fixture does not drive the ESP32.
  high := pio.StateMachine CAPTURE-PROGRAM --in-pins=[32]
  try:
    expect-throw "ALREADY_IN_USE": gpio.Pin 32 --input
    expect-throw "INVALID_ARGUMENT":
      pio.StateMachine ECHO-PROGRAM --in-pins=[1] --out-pins=[40]
  finally:
    high.close
  pin := gpio.Pin 32 --input
  pin.close
  print "pio-rp2350: program sharing and upper pins PASS"

irq-tests:
  sm := pio.StateMachine SIGNAL-PROGRAM --irqs=[0]
  try:
    5.repeat:
      sm.start
      sleep --ms=1
      sm.wait-for-irq 0
      sm.pause
      sm.reset
  finally:
    sm.close
  print "pio-rp2350: IRQ persistence and reset PASS"
