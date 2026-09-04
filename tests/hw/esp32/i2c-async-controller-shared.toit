// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import i2c
import monitor
import rmt
import system
import uart

import .test
import .variants

UART-RX1 ::= Variant.CURRENT.board-connection-pin1
UART-TX1 ::= Variant.CURRENT.board-connection-pin2
UART-RX2 ::= Variant.CURRENT.board-connection-pin2
UART-TX2 ::= Variant.CURRENT.board-connection-pin1

I2C-SDA ::= Variant.CURRENT.board-connection-pin3
I2C-SCL ::= Variant.CURRENT.board-connection-pin5
I2C-SCL-PROBE ::= Variant.CURRENT.board-connection-pin6

ADDRESS ::= 0x42
MISSING-ADDRESS ::= 0x71

READY ::= 0xa5
OK ::= 0x5a

SET ::= 1
RECONFIGURE ::= 2
DYNAMIC-READ ::= 3
CLOSE ::= 4
EXPECT-WRITE ::= 5
QUEUE-READ ::= 6
WRITE-READ ::= 7
TIMEOUT-READ ::= 8
STRETCH-CLOCK ::= 9

REGISTER-7 ::= 1
REGISTER-10 ::= 2
DYNAMIC ::= 3

main-board1:
  run-test: test-board1

test-board1:
  port := uart.Port --rx=UART-RX1 --tx=UART-TX1 --baud-rate=115_200
  expect-equals READY port.in.read-byte

  if system.architecture == system.ARCHITECTURE-ESP32:
    test-board1-esp32 port
    return

  bus := i2c.Bus --sda=I2C-SDA --scl=I2C-SCL --frequency=100_000 --pull-up=false

  // Probe completion exercises both DONE and NACK callbacks. Scanning repeats
  // this over enough transactions to catch stale completion state.
  expect (bus.test ADDRESS)
  expect-not (bus.test MISSING-ADDRESS --timeout-ms=5)
  found := bus.scan --timeout-ms=5
  expect (found.contains ADDRESS)
  expect-not (found.contains MISSING-ADDRESS)

  missing := bus.device MISSING-ADDRESS
  expect-throw "I2C_NACK": missing.write #[1]
  expect-throw "I2C_NACK": missing.read 1
  missing.close

  // This is an exposed controller configuration, and also verifies that the
  // async path applies the per-device ACK policy before dispatch.
  unchecked := bus.device MISSING-ADDRESS --disable-ack-check
  unchecked.write #[1, 2, 3]
  unchecked.close

  device := bus.device ADDRESS --frequency=100_000
  registers := device.registers
  initial := make-data 256 0x31
  set-registers port 0 initial

  expect-equals initial (registers.read-bytes 0 initial.size)
  expect-equals (wrapped initial 17 1024) (registers.read-bytes 17 1024)

  into := ByteArray 40: 0xee
  device.write #[23]
  device.read-into into 19
  expect-equals (wrapped initial 23 19) (into[0..19])
  expect-equals (ByteArray 21: 0xee) (into[19..])

  expect-throw "ESP_ERR_INVALID_ARG": device.write #[]
  expect-throw "ESP_ERR_INVALID_ARG": device.read 0
  expect-throw "ESP_ERR_INVALID_ARG": device.write-read #[0] 0
  expect-throw "OUT_OF_RANGE": device.read-into (ByteArray 1) 2

  // All tasks share one native bus operation slot. Each write-read remains
  // atomic even under contention and no caller enters IDF's blocking queue.
  done := List 4: monitor.Latch
  errors := List 4: null
  4.repeat: | task-index/int |
    task::
      errors[task-index] = catch:
        25.repeat: | iteration/int |
          index := task-index * 53 + iteration
          expected := initial[index]
          expect-equals #[expected] (device.write-read #[index] 1)
      done[task-index].set true
  done.do: it.get
  errors.do: | error/any? |
    if error: throw error

  device.close
  slow := bus.device ADDRESS --frequency=50_000
  probe := rmt.In
      I2C-SCL-PROBE
      --resolution=1_000_000
      --memory-blocks=8
      --pull-up
      --dma
  probe.start-reading --min-ns=500 --max-ns=20_000_000
  slow.write-read #[0] 8
  slow-signals := with-timeout --ms=500: probe.wait-for-data
  slow-low-periods := []
  slow-signals.size.repeat: | i/int |
    if (slow-signals.level i) == 0:
      slow-low-periods.add (slow-signals.period i)
  slow-low-periods.sort --in-place
  slow-low := slow-low-periods[slow-low-periods.size / 2]
  slow.close

  fast := bus.device ADDRESS --frequency=400_000
  probe.start-reading --min-ns=500 --max-ns=20_000_000
  fast.write-read #[0] 8
  fast-signals := with-timeout --ms=500: probe.wait-for-data
  fast-low-periods := []
  fast-signals.size.repeat: | i/int |
    if (fast-signals.level i) == 0:
      fast-low-periods.add (fast-signals.period i)
  fast-low-periods.sort --in-place
  fast-low := fast-low-periods[fast-low-periods.size / 2]
  probe.close
  print "Async I2C frequency probe: 50kHz low $(slow-low)us, 400kHz low $(fast-low)us"
  expect slow-low >= 6
  expect fast-low < 6
  expect slow-low > fast-low * 2
  device = fast

  device.close
  reconfigure port REGISTER-10

  // Keep both address widths for the same raw address registered. ESP-IDF's
  // callback must report completion for the actual transaction device.
  seven := bus.device ADDRESS
  ten := bus.device ADDRESS --address-size=10 --frequency=100_000
  wide := make-data 256 0x87
  set-registers port 0 wide
  expect-equals (wrapped wide 211 73) (ten.write-read #[211] 73)
  expect-throw "I2C_NACK": seven.write #[1]
  // Reset the target after deliberately addressing it with the wrong width.
  // This isolates controller recovery from the target peripheral's own
  // recovery after seeing a colliding 7-bit address prefix.
  reconfigure port REGISTER-10
  set-registers port 0 wide
  expect-equals #[wide[3]] (ten.write-read #[3] 1)
  seven.close
  ten.close

  reconfigure port DYNAMIC

  // Prove that the suspended controller task does not prevent another Toit
  // task from running during successful clock stretching.
  print "Async I2C: dynamic clock-stretch recovery"
  stretched := bus.device ADDRESS --timeout-us=30_000
  expected := make-data 17 0xc4
  send-command port DYNAMIC-READ [expected, encode-u16 10]
  ran-while-waiting := monitor.Latch
  task::
    sleep --ms=2
    ran-while-waiting.set true
  start := Time.monotonic-us
  expect-equals expected (stretched.read expected.size)
  elapsed := Time.monotonic-us - start
  expect ran-while-waiting.has-value
  expect elapsed >= 9_000
  expect elapsed < 30_000
  expect-equals OK port.in.read-byte
  stretched.close

  // A task deadline aborts the native transaction even when every individual
  // stretch is shorter than the device's SCL timeout. The bus must be reusable
  // after the target releases the clock.
  print "Async I2C: deadline abort recovery"
  abortable := bus.device ADDRESS --timeout-us=100_000
  send-command port DYNAMIC-READ [#[0x5a], encode-u16 20]
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=2: abortable.read 1
  expect-equals OK port.in.read-byte
  expect (bus.test ADDRESS)

  // Cancellation must run the abort cleanup before the task terminates and
  // releases the bus mutex.
  send-command port DYNAMIC-READ [#[0x6b], encode-u16 20]
  canceled := monitor.Latch
  operation := task::
    try:
      abortable.read 1
    finally:
      critical-do: canceled.set true
  sleep --ms=2
  operation.cancel
  with-timeout --ms=100: canceled.get
  expect-equals OK port.in.read-byte
  expect (bus.test ADDRESS)
  abortable.close

  // Hold SCL externally before START. The per-device stretch timeout applies
  // to SCL pulses after a transaction has started, so use the task deadline
  // to abort this bus-not-idle case. Releasing the probe pin lets us verify
  // that the same bus and target recover immediately.
  print "Async I2C: external SCL deadline recovery"
  external-timeout-device := bus.device ADDRESS --timeout-us=2_000
  send-command port STRETCH-CLOCK [encode-u16 10]
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=3: external-timeout-device.read 1
  expect-equals OK port.in.read-byte
  expect (bus.test ADDRESS)
  external-timeout-device.close

  recovered := bus.device ADDRESS --timeout-us=30_000
  recovered-data := #[0x6b]
  send-command port DYNAMIC-READ [recovered-data, encode-u16 1]
  expect-equals recovered-data (recovered.read 1)
  expect-equals OK port.in.read-byte
  recovered.close

  // Exercise the controller pull-up configuration and resource reuse after a
  // large number of asynchronous transactions and errors.
  bus.close
  bus = i2c.Bus --sda=I2C-SDA --scl=I2C-SCL --frequency=100_000 --pull-up
  expect-not (bus.test MISSING-ADDRESS --timeout-ms=5)
  bus.close

  // A timed-out target transaction cannot be completed or torn down cleanly
  // by the current ESP-IDF target driver. Keep this destructive edge case
  // last; the test rig resets both boards before the next test.
  bus = i2c.Bus --sda=I2C-SDA --scl=I2C-SCL --frequency=100_000 --pull-up
  timeout-device := bus.device ADDRESS --timeout-us=2_000
  timed-out := make-data 11 0xb1
  send-command port TIMEOUT-READ [encode-u16 10]
  expect-throw "I2C_TIMEOUT": timeout-device.read timed-out.size

test-board1-esp32 port/uart.Port -> none:
  bus := i2c.Bus --sda=I2C-SDA --scl=I2C-SCL --frequency=100_000 --pull-up
  expect-throw "INVALID_ARGUMENT": bus.scan --timeout-ms=0
  expect-throw "INVALID_ARGUMENT": bus.test ADDRESS --timeout-ms=0
  expect-throw "INVALID_ARGUMENT": bus.device ADDRESS --timeout-us=0
  expect (bus.test ADDRESS)
  expect-not (bus.test MISSING-ADDRESS --timeout-ms=5)

  missing := bus.device MISSING-ADDRESS
  expect-throw "I2C_NACK": missing.write #[1]
  expect-throw "I2C_NACK": missing.read 1
  missing.close

  unchecked := bus.device MISSING-ADDRESS --disable-ack-check
  unchecked.write #[1, 2, 3]
  unchecked.close

  device := bus.device ADDRESS
  [1, 31, 32, 127, 255].do: | size/int |
    data := make-data size (0x20 + size)
    send-command port EXPECT-WRITE [data]
    device.write data
    expect-equals OK port.in.read-byte

    response := make-data size (0x80 + size)
    send-command port QUEUE-READ [response]
    expect-equals response (device.read size)
    expect-equals OK port.in.read-byte

  tx := make-data 97 0x43
  rx := make-data 193 0xb4
  send-command port WRITE-READ [tx, rx]
  expect-equals rx (device.write-read tx rx.size)
  expect-equals OK port.in.read-byte

  // Exercise contention on the controller operation slot. The target queues
  // enough bytes for all reads before any controller task is started.
  concurrent := ByteArray 100: 0xa5
  send-command port QUEUE-READ [concurrent]
  done := List 4: monitor.Latch
  errors := List 4: null
  4.repeat: | task-index/int |
    task::
      errors[task-index] = catch:
        25.repeat:
          expect-equals #[0xa5] (device.read 1)
      done[task-index].set true
  done.do: it.get
  errors.do: | error/any? |
    if error: throw error
  expect-equals OK port.in.read-byte

  device.close
  probe := rmt.In
      I2C-SCL-PROBE
      --resolution=1_000_000
      --memory-blocks=8
      --pull-up

  slow := bus.device ADDRESS --frequency=50_000
  probe.start-reading --min-ns=500 --max-ns=20_000_000
  send-command port WRITE-READ [#[0x23], #[0x45]]
  expect-equals #[0x45] (slow.write-read #[0x23] 1)
  expect-equals OK port.in.read-byte
  slow-signals := with-timeout --ms=500: probe.wait-for-data
  slow-low-periods := []
  slow-signals.size.repeat: | i/int |
    if (slow-signals.level i) == 0:
      slow-low-periods.add (slow-signals.period i)
  slow-low-periods.sort --in-place
  slow-low := slow-low-periods[slow-low-periods.size / 2]
  slow.close

  fast := bus.device ADDRESS --frequency=400_000
  probe.start-reading --min-ns=500 --max-ns=20_000_000
  send-command port WRITE-READ [#[0x67], #[0x89]]
  expect-equals #[0x89] (fast.write-read #[0x67] 1)
  expect-equals OK port.in.read-byte
  fast-signals := with-timeout --ms=500: probe.wait-for-data
  fast-low-periods := []
  fast-signals.size.repeat: | i/int |
    if (fast-signals.level i) == 0:
      fast-low-periods.add (fast-signals.period i)
  fast-low-periods.sort --in-place
  fast-low := fast-low-periods[fast-low-periods.size / 2]
  probe.close
  print "Async I2C classic frequency probe: 50kHz low $(slow-low)us, 400kHz low $(fast-low)us"
  expect slow-low >= 6
  expect fast-low < 6
  expect slow-low > fast-low * 2
  fast.close

  // A task deadline must abort the native operation, wake the suspended task,
  // and leave the controller usable for the next transaction.
  abortable := bus.device ADDRESS --timeout-us=100_000
  // Classic ESP32 cannot clock-stretch from its target read callback. Instead,
  // board 2 holds SCL low through the fixture's resistor-coupled probe pin.
  send-command port STRETCH-CLOCK [encode-u16 20]
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=2: abortable.read 1
  expect-equals OK port.in.read-byte
  expect (bus.test ADDRESS)

  // Cancellation must run the abort cleanup before the task terminates and
  // releases the bus mutex.
  send-command port STRETCH-CLOCK [encode-u16 20]
  canceled := monitor.Latch
  operation := task::
    try:
      abortable.read 1
    finally:
      critical-do: canceled.set true
  sleep --ms=2
  operation.cancel
  with-timeout --ms=100: canceled.get
  expect-equals OK port.in.read-byte
  expect (bus.test ADDRESS)
  abortable.close

  port.out.write-byte CLOSE
  port.out.flush
  expect-equals OK port.in.read-byte
  device.close
  bus.close
  port.close

main-board2:
  run-test --background: test-board2

test-board2:
  if system.architecture == system.ARCHITECTURE-ESP32:
    test-board2-esp32
    return

  register-target/i2c.RegisterTarget? := make-register-target REGISTER-7
  dynamic-target/i2c.Target? := null
  port := uart.Port --rx=UART-RX2 --tx=UART-TX2 --baud-rate=115_200
  send-byte port READY

  while true:
    command := port.in.read-byte
    if command == CLOSE:
      if register-target: register-target.close
      if dynamic-target: dynamic-target.close
      send-byte port OK
      port.close
      return

    parts := read-parts port
    if command == RECONFIGURE:
      if register-target: register-target.close
      if dynamic-target: dynamic-target.close
      register-target = null
      dynamic-target = null
      config := parts[0][0]
      if config == DYNAMIC:
        dynamic-target = make-dynamic-target
      else:
        register-target = make-register-target config
      send-byte port READY
      send-byte port OK
    else if command == SET:
      register-target.write (decode-u16 parts[0]) parts[1]
      send-byte port READY
      send-byte port OK
    else if command == DYNAMIC-READ:
      send-byte port READY
      dynamic-target.wait-for-read-request: |request-count/int|
        expect-equals 1 request-count
        sleep --ms=(decode-u16 parts[1])
        parts[0]
      send-byte port OK
    else if command == STRETCH-CLOCK:
      stretcher := gpio.Pin I2C-SCL-PROBE --output --open-drain --value=0
      send-byte port READY
      sleep --ms=(decode-u16 parts[0])
      stretcher.set 1
      stretcher.close
      send-byte port OK
    else if command == TIMEOUT-READ:
      send-byte port READY
      dynamic-target.wait-for-read-request: |request-count/int|
        expect-equals 1 request-count
        sleep --ms=(decode-u16 parts[0])
        // The controller has aborted this transaction. The current ESP-IDF
        // target peripheral cannot finish or close it cleanly, so leave cleanup
        // to the test rig's board reset.
        while true: sleep --ms=1_000
    else:
      throw "Unknown command: $command"

test-board2-esp32 -> none:
  target := i2c.Target
      --sda=I2C-SDA
      --scl=I2C-SCL
      --address=ADDRESS
      --send-buffer-size=512
      --receive-buffer-size=512
      --pull-up
  port := uart.Port --rx=UART-RX2 --tx=UART-TX2 --baud-rate=115_200
  send-byte port READY

  while true:
    command := port.in.read-byte
    if command == CLOSE:
      target.close
      send-byte port OK
      port.close
      return
    parts := read-parts port
    if command == EXPECT-WRITE:
      send-byte port READY
      expect-equals parts[0] target.read
      send-byte port OK
    else if command == QUEUE-READ:
      target.write parts[0]
      send-byte port READY
      target.wait-for-read-request: |request-count/int|
        expect-equals 1 request-count
        #[ ]
      send-byte port OK
    else if command == WRITE-READ:
      target.write parts[1]
      send-byte port READY
      expect-equals parts[0] target.read
      send-byte port OK
    else if command == STRETCH-CLOCK:
      stretcher := gpio.Pin I2C-SCL-PROBE --output --open-drain --value=0
      send-byte port READY
      sleep --ms=(decode-u16 parts[0])
      stretcher.set 1
      stretcher.close
      send-byte port OK
    else:
      throw "Unknown command: $command"

make-register-target config/int -> i2c.RegisterTarget:
  return i2c.RegisterTarget
      --sda=I2C-SDA
      --scl=I2C-SCL
      --address=ADDRESS
      --address-size=(config == REGISTER-10 ? 10 : 7)
      --register-count=256
      --register-address-size=1
      --receive-buffer-size=128
      --pull-up

make-dynamic-target -> i2c.Target:
  return i2c.Target
      --sda=I2C-SDA
      --scl=I2C-SCL
      --address=ADDRESS
      --send-buffer-size=64
      --receive-buffer-size=64
      --pull-up

set-registers port/uart.Port start/int data/ByteArray -> none:
  send-command port SET [encode-u16 start, data]
  expect-equals OK port.in.read-byte

reconfigure port/uart.Port config/int -> none:
  send-command port RECONFIGURE [#[config]]
  expect-equals OK port.in.read-byte

send-command port/uart.Port command/int parts/List -> none:
  port.out.write-byte command
  port.out.write-byte parts.size
  parts.do: | part/ByteArray |
    port.out.little-endian.write-uint16 part.size
    port.out.write part
  port.out.flush
  expect-equals READY port.in.read-byte

read-parts port/uart.Port -> List:
  count := port.in.read-byte
  return List count: | _ |
    size := port.in.little-endian.read-uint16
    port.in.read-bytes size

send-byte port/uart.Port value/int -> none:
  port.out.write-byte value
  port.out.flush

encode-u16 value/int -> ByteArray:
  return #[value & 0xff, (value >> 8) & 0xff]

decode-u16 bytes/ByteArray -> int:
  return bytes[0] | (bytes[1] << 8)

make-data size/int seed/int -> ByteArray:
  return ByteArray size: (seed + 17 * it) & 0xff

wrapped data/ByteArray start/int count/int -> ByteArray:
  return ByteArray count: data[(start + it) % data.size]
