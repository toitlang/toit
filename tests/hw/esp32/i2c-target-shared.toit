// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
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
// Pin 5 is resistor-coupled to pin 6 on board 1. Pin 6 is deliberately left
// free so later timing tests can use it as a non-invasive SCL probe.
I2C-SCL ::= Variant.CURRENT.board-connection-pin5
I2C-SCL-PROBE ::= Variant.CURRENT.board-connection-pin6

ADDRESS ::= 0x42
TEN-BIT-ADDRESS ::= 0x2aa
FREQUENCY ::= 100_000

READY ::= 0xa5
OK ::= 0x5a

WRITE ::= 1
QUEUE-READ ::= 2
WRITE-READ ::= 3
CLOSE ::= 4
DYNAMIC-READ ::= 5
RECONFIGURE ::= 6
OVERFLOW ::= 7
TRANSACTION-OVERFLOW ::= 8
CONCURRENT-QUEUE-READ ::= 9
THROWING-READ ::= 10
HANDLER-SEQUENCE ::= 12
RACING-QUEUE-READ ::= 13
HANDLER-WRITE ::= 14
ABORTED-HANDLER ::= 15
HANDLER-TIMEOUT ::= 16

DEFAULT-CONFIG ::= 0
TEN-BIT-CONFIG ::= 1
SMALL-BUFFER-CONFIG ::= 2
BROADCAST-CONFIG ::= 3
CUSTOM-DEFAULT-CONFIG ::= 4

main-board1:
  run-test: test-board1

test-board1:
  port := uart.Port --rx=UART-RX1 --tx=UART-TX1 --baud-rate=115_200
  expect-equals READY port.in.read-byte

  bus := i2c.Bus --sda=I2C-SDA --scl=I2C-SCL --frequency=FREQUENCY --pull-up
  expect (bus.test ADDRESS)
  device := bus.device ADDRESS

  implicit-default := ByteArray 16 --initial=0xff
  expect-equals implicit-default (device.read implicit-default.size)

  device.close
  reconfigure port CUSTOM-DEFAULT-CONFIG
  device = bus.device ADDRESS
  custom-default := #[0x31, 0xa7, 0x5c]
  custom-read-size := system.architecture == system.ARCHITECTURE-ESP32
      ? custom-default.size
      : custom-default.size * 3
  expected-custom-default := ByteArray custom-read-size:
    custom-default[it % custom-default.size]
  expect-equals expected-custom-default (device.read expected-custom-default.size)

  if system.architecture != system.ARCHITECTURE-ESP32:
    first-response := #[0x10, 0x11, 0x12]
    second-response := #[0x20, 0x21, 0x22, 0x23]
    third-response := #[0x30, 0x31, 0x32]
    send-command port HANDLER-SEQUENCE [first-response, second-response, third-response]
    // A short controller transaction discards the unused handler bytes. The
    // next transaction calls the handler again.
    expect-equals first-response[..2] (device.read 2)
    // If that response is shorter than the controller transaction, the same
    // handler is called again while SCL remains stretched.
    expected-response := second-response + third-response
    expect-equals expected-response (device.read expected-response.size)
    // The next request makes the response block leave non-locally. The
    // persistent serving scope must restore the default for that same request.
    expect-equals custom-default (device.read custom-default.size)
    expect-equals OK port.in.read-byte

    send-command port THROWING-READ []
    // An exception from the handler also restores the default without closing
    // the target.
    expect-equals custom-default (device.read custom-default.size)
    expect-equals OK port.in.read-byte
    expect-equals custom-default (device.read custom-default.size)
    expect (bus.test ADDRESS)

    recovered-handler-response := make-data 7 0x5e
    send-command port HANDLER-TIMEOUT [recovered-handler-response]
    // The first handler deliberately misses its response deadline. The target
    // must release this already-waiting controller with the default response.
    expect-equals custom-default (device.read custom-default.size)
    // Wait until board 2 has observed the timeout and restored the fallback,
    // then let it re-enter handler mode.
    expect-equals READY port.in.read-byte
    send-byte port OK
    // Prove that a later request receives a normal dynamic response.
    expect-equals READY port.in.read-byte
    expect-equals recovered-handler-response (device.read recovered-handler-response.size)
    expect-equals OK port.in.read-byte

    abandoned-response := make-data 200 0x48
    send-command port ABORTED-HANDLER [abandoned-response]
    expect-equals abandoned-response[..16] (device.read 16)
    expect-equals OK port.in.read-byte
    // The timeout abandons the remainder of the handler response. It must not
    // leak ahead of the restored fallback, now or on a later transaction.
    expect-equals custom-default (device.read custom-default.size)
    expect-equals custom-default (device.read custom-default.size)

    handler-write := make-data 11 0x64
    handler-read := make-data 9 0xa2
    send-command port HANDLER-WRITE [handler-write, handler-read]
    device.write handler-write
    expect-equals handler-read (device.read handler-read.size)
    expect-equals OK port.in.read-byte

  device.close
  reconfigure port DEFAULT-CONFIG
  device = bus.device ADDRESS

  [1, 2, 15, 31, 32, 63].do: | size/int |
    data := make-data size size
    send-command port WRITE [data]
    device.write data
    expect-equals OK port.in.read-byte

  [1, 2, 15, 31, 32, 63].do: | size/int |
    expected := make-data size (size + 0x40)
    send-command port QUEUE-READ [expected]
    expect-equals expected (device.read size)
    expect-equals OK port.in.read-byte

  if system.architecture != system.ARCHITECTURE-ESP32:
    queued-prefix := #[0x75, 0x86, 0x97]
    send-command port QUEUE-READ [queued-prefix]
    expect-equals (queued-prefix + (ByteArray 5 --initial=0xff)) (device.read 8)
    expect-equals OK port.in.read-byte

  // Queueing a response during an active default transaction must not replace
  // or splice into that response. The queued bytes belong to the next
  // transaction.
  device.close
  reconfigure port DEFAULT-CONFIG
  device = bus.device ADDRESS --frequency=10_000
  racing-response := make-data 17 0xd3
  send-command port RACING-QUEUE-READ [racing-response]
  fallback-read-size := system.architecture == system.ARCHITECTURE-ESP32 ? 32 : 64
  expect-equals (ByteArray fallback-read-size --initial=0xff) (device.read fallback-read-size)
  expect-equals racing-response (device.read racing-response.size)
  expect-equals OK port.in.read-byte

  device.close
  reconfigure port DEFAULT-CONFIG
  device = bus.device ADDRESS

  if system.architecture != system.ARCHITECTURE-ESP32:
    expected := make-data 17 0x91
    send-command port DYNAMIC-READ [expected]
    // GPIO38 drives the S3 devkit's onboard RGB LED and needs a local pull-up
    // to be a reliable high-impedance probe through the 5K resistor.
    probe := rmt.In
        I2C-SCL-PROBE
        --resolution=1_000_000
        --memory-blocks=8
        --pull-up
        --dma
    probe.start-reading --min-ns=1_000 --max-ns=20_000_000
    start := Time.monotonic-us
    expect-equals expected (device.read expected.size)
    elapsed := Time.monotonic-us - start
    expect elapsed >= 10_000
    expect elapsed < 100_000
    expect-equals OK port.in.read-byte
    scl-signals := probe.wait-for-data
    longest-low := 0
    scl-signals.size.repeat: | i/int |
      if (scl-signals.level i) == 0:
        longest-low = max longest-low (scl-signals.period i)
    print "I2C SCL probe: $(scl-signals.size) signals, longest low $(longest-low)us"
    // Ordinary 100kHz SCL low periods are about 5us. The target deliberately
    // waits 10ms after its request callback, which must be visible as one
    // continuous SCL-low stretch on the resistor-coupled probe pin.
    expect longest-low >= 9_000
    expect longest-low < 20_000
    probe.close

  tx := make-data 19 0x71
  expected-rx := make-data 23 0x29
  send-command port WRITE-READ [tx, expected-rx]
  expect-equals expected-rx (device.write-read tx expected-rx.size)
  expect-equals OK port.in.read-byte

  device.close
  reconfigure port TEN-BIT-CONFIG
  device = bus.device TEN-BIT-ADDRESS --address-bit-size=10
  ten-bit-write := make-data 29 0x37
  send-command port WRITE [ten-bit-write]
  device.write ten-bit-write
  expect-equals OK port.in.read-byte
  ten-bit-read := make-data 27 0xb2
  send-command port QUEUE-READ [ten-bit-read]
  expect-equals ten-bit-read (device.read ten-bit-read.size)
  expect-equals OK port.in.read-byte

  device.close
  // Recreating the target resets its dropped-transaction counter, making the
  // exact count checked by board 2 independent of the preceding overflow.
  reconfigure port SMALL-BUFFER-CONFIG
  device = bus.device ADDRESS
  small-buffer-write := make-data 31 0x84
  send-command port WRITE [small-buffer-write]
  device.write small-buffer-write
  expect-equals OK port.in.read-byte
  small-buffer-read := make-data 8 0x13
  send-command port QUEUE-READ [small-buffer-read]
  expect-equals small-buffer-read (device.read small-buffer-read.size)
  expect-equals OK port.in.read-byte

  if system.architecture != system.ARCHITECTURE-ESP32:
    device.close
    // Isolate the concurrency check from any target TX/FIFO state left by the
    // preceding short controller read.
    reconfigure port SMALL-BUFFER-CONFIG
    device = bus.device ADDRESS --frequency=10_000

    // The first write is larger than the hardware FIFO and native target
    // buffer combined, so it suspends while holding the write mutex. A second
    // writer must not overtake it when the controller frees buffer space.
    concurrent-first := make-data 48 0x35
    concurrent-second := make-data 8 0xb5
    send-command port CONCURRENT-QUEUE-READ [concurrent-first, concurrent-second]
    concurrent-expected := ByteArray (concurrent-first.size + concurrent-second.size)
    concurrent-expected.replace 0 concurrent-first
    concurrent-expected.replace concurrent-first.size concurrent-second
    expect-equals concurrent-expected (device.read concurrent-expected.size)
    expect-equals OK port.in.read-byte

  first := make-data 31 0x51
  second := make-data 31 0xc1
  send-command port OVERFLOW [first]
  device.write first
  // Keep producing complete transactions while board 2 deliberately leaves
  // its application receive queue unread. The extra transactions also make
  // finalization independent of the peripheral's boundary notification lag.
  8.repeat: device.write second
  expect-equals OK port.in.read-byte

  // Distinguish a transaction larger than the driver's receive buffer from
  // an application that merely leaves too many complete transactions unread.
  reconfigure port SMALL-BUFFER-CONFIG
  oversized := make-data 63 0x6d
  send-command port TRANSACTION-OVERFLOW []
  device.write oversized
  // Force subsequent address boundaries so all peripheral revisions report
  // the completed oversized write before board 2 checks the overflow count.
  device.write #[0x00]
  device.write #[0x01]
  expect-equals OK port.in.read-byte

  if system.architecture != system.ARCHITECTURE-ESP32:
    device.close
    reconfigure port BROADCAST-CONFIG
    device = bus.device ADDRESS
    general-call := bus.device 0
    broadcast-data := make-data 21 0xe3
    send-command port WRITE [broadcast-data]
    general-call.write broadcast-data
    expect-equals OK port.in.read-byte
    general-call.close

  port.out.write-byte CLOSE
  port.out.flush
  expect-equals OK port.in.read-byte

  device.close
  bus.close
  port.close

main-board2:
  run-test --background: test-board2

test-board2:
  expect-throw "INVALID_ARGUMENT":
    i2c.Target
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=ADDRESS
        --default-response=#[]
  expect-throw "INVALID_ARGUMENT":
    i2c.Target
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=ADDRESS
        --default-response=(ByteArray (i2c.MAX-DEFAULT-RESPONSE-SIZE + 1))

  target := make-target DEFAULT-CONFIG
  expect-null target.try-read
  expect-equals 0 target.dropped-receive-count
  if system.architecture == system.ARCHITECTURE-ESP32:
    expect-throw "UNSUPPORTED":
      target.serve-read-requests: #[]

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
    if command == RECONFIGURE:
      target.close
      target = make-target parts[0][0]
      send-byte port READY
      send-byte port OK
    else if command == WRITE:
      send-byte port READY
      expect-equals parts[0] target.read
      send-byte port OK
    else if command == QUEUE-READ:
      target.write parts[0]
      send-byte port READY
      send-byte port OK
    else if command == DYNAMIC-READ:
      done := monitor.Semaphore
      task::
        catch:
          with-timeout --ms=100:
            target.serve-read-requests:
              sleep --ms=10
              parts[0]
        done.up
      // Spawning yields to the new task. An explicit second yield makes the
      // test independent of that implementation detail and lets it reach the
      // request wait after suppressing the fallback.
      yield
      expect-throw "INVALID_STATE": target.try-write #[0x55]
      send-byte port READY
      done.down
      send-byte port OK
    else if command == THROWING-READ:
      done := monitor.Semaphore
      task::
        expect-throw "HANDLER_ERROR":
          target.serve-read-requests:
            throw "HANDLER_ERROR"
        done.up
      yield
      send-byte port READY
      done.down
      send-byte port OK
    else if command == HANDLER-SEQUENCE:
      done := monitor.Semaphore
      task::
        serve-handler-sequence target parts
        done.up
      yield
      send-byte port READY
      done.down
      send-byte port OK
    else if command == HANDLER-WRITE:
      invocations := 0
      done := monitor.Semaphore
      task::
        catch:
          with-timeout --ms=100:
            target.serve-read-requests:
              invocations++
              parts[1]
        done.up
      yield
      send-byte port READY
      expect-equals parts[0] target.read
      done.down
      expect-equals 1 invocations
      send-byte port OK
    else if command == HANDLER-TIMEOUT:
      first-done := monitor.Semaphore
      task::
        expect-throw DEADLINE-EXCEEDED-ERROR:
          target.serve-read-requests --response-timeout-us=5_000:
            sleep --ms=20
            parts[0]
        first-done.up
      // The new task runs until serve-read-requests waits for a controller.
      yield
      send-byte port READY
      first-done.down
      // Do not re-enter handler mode until the controller has consumed the
      // fallback released by the timeout.
      send-byte port READY
      expect-equals OK port.in.read-byte
      done := monitor.Semaphore
      task::
        catch:
          with-timeout --ms=100:
            target.serve-read-requests: parts[0]
        done.up
      yield
      send-byte port READY
      done.down
      send-byte port OK
    else if command == ABORTED-HANDLER:
      done := monitor.Semaphore
      task::
        catch:
          with-timeout --ms=50:
            target.serve-read-requests: parts[0]
        done.up
      yield
      send-byte port READY
      done.down
      send-byte port OK
    else if command == WRITE-READ:
      target.write parts[1]
      send-byte port READY
      expect-equals parts[0] target.read
      send-byte port OK
    else if command == OVERFLOW:
      send-byte port READY
      // Keep the application receive buffer occupied until the subsequent
      // transactions have all reached the ISR.
      sleep --ms=100
      got-transaction := false
      got-overflow := false
      // Delivery of the valid transaction and the overflow notification are
      // independent ISR events, so their observable order is not defined.
      with-timeout --ms=100:
        while not (got-transaction and got-overflow):
          error := catch --unwind=(: it != "OVERFLOW"):
            transaction := target.read
            if transaction == parts[0]: got-transaction = true
          if error == "OVERFLOW":
            expect (not got-overflow)
            got-overflow = true
      expect target.dropped-receive-count >= 1
      send-byte port OK
    else if command == TRANSACTION-OVERFLOW:
      send-byte port READY
      sleep --ms=100
      expect-throw "OVERFLOW": target.try-read
      expect-equals 1 target.dropped-receive-count
      send-byte port OK
    else if command == CONCURRENT-QUEUE-READ:
      expect system.architecture != system.ARCHITECTURE-ESP32
      start-second := monitor.Latch
      second-done := monitor.Latch
      task::
        start-second.get
        target.write parts[1]
        second-done.set true
      task::
        // The synchronous first write below fills the native buffer and
        // suspends while holding the write mutex. Only then make the second
        // writer runnable and let the controller start consuming bytes.
        sleep --ms=5
        start-second.set true
        send-byte port READY
      target.write parts[0]
      second-done.get
      send-byte port OK
    else if command == RACING-QUEUE-READ:
      send-byte port READY
      sleep --ms=10
      target.write parts[0]
      send-byte port OK
    else:
      throw "Unknown command: $command"

serve-handler-sequence target/i2c.Target responses/List -> none:
  index := -1
  target.serve-read-requests:
    index++
    if index == 0:
      // An empty response asks the same handler again without releasing SCL.
      #[]
    else if index <= responses.size:
      responses[index - 1]
    else:
      return

make-target config/int -> i2c.Target:
  if config == DEFAULT-CONFIG:
    return i2c.Target
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=ADDRESS
        --send-buffer-size=128
        --receive-buffer-size=256
        --pull-up
  if config == TEN-BIT-CONFIG:
    return i2c.Target
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=TEN-BIT-ADDRESS
        --address-bit-size=10
        --send-buffer-size=64
        --receive-buffer-size=64
        --pull-up
  if config == SMALL-BUFFER-CONFIG:
    return i2c.Target
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=ADDRESS
        --send-buffer-size=8
        --receive-buffer-size=32
        --no-pull-up
  if config == BROADCAST-CONFIG:
    return i2c.Target
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=ADDRESS
        --send-buffer-size=32
        --receive-buffer-size=32
        --pull-up
        --broadcast
  if config == CUSTOM-DEFAULT-CONFIG:
    return i2c.Target
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=ADDRESS
        --send-buffer-size=128
        --receive-buffer-size=256
        --default-response=#[0x31, 0xa7, 0x5c]
        --pull-up
  unreachable

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

make-data size/int seed/int -> ByteArray:
  return ByteArray size: (seed + 17 * it) & 0xff
