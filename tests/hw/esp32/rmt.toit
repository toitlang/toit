// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests a simple pulse from the RMT peripheral.

Setup:
Connect pin 18 and 19 with a 330 Ohm resistor. The resistor isn't
  strictly necessary but can prevent accidental short circuiting.

Similarly, connect pin 21 to pin 19 with a 330 Ohm resistor. We will
  use that one to pull the line high.
*/

import rmt
import gpio
import monitor
import expect show *

import .test

RMT-PIN-1 ::= 18
RMT-PIN-2 ::= 19
RMT-PIN-3 ::= 21

// Because of the resistors and a weak pull-up, the reading isn't fully precise.
// We allow 5us error.
SLACK ::= 5

// Test that the channel resources are correctly handed out.
test-resource pin/gpio.Pin:
  // There are 8 channels, each having one memory block.
  // If we request a channel with more than one memory block, then the
  // next channel becomes unusable.
  channels := []
  8.repeat: channels.add (rmt.Channel pin --input)
  expect-throw "ALREADY_IN_USE": rmt.Channel pin --input
  channels.do: it.close
  // Now that we closed all channels we are again OK to get one.
  channel := rmt.Channel pin --input
  channel.close

  channels = []
  // We should be able to allocate 4 channels with 2 memory blocks.
  4.repeat: channels.add (rmt.Channel pin --memory-block-count=2 --input)
  expect-throw "ALREADY_IN_USE": rmt.Channel pin --input
  channels.do: it.close
  // Now that we closed all channels we are again OK to get one.
  channel = rmt.Channel pin --input
  channel.close

  channels = []
  // We should be able to allocate 2 channels with 3 memory blocks, and one with 2
  2.repeat: channels.add (rmt.Channel pin --memory-block-count=3 --input)
  channels.add (rmt.Channel pin --memory-block-count=2 --input)
  expect-throw "ALREADY_IN_USE": rmt.Channel pin --input
  channels.do: it.close
  // Now that we closed all channels we are again OK to get one.
  channel = rmt.Channel pin --input
  channel.close

  channels = []
  // We should be able to allocate 2 channels with 4 memory blocks.
  2.repeat: channels.add (rmt.Channel pin --memory-block-count=4 --input)
  expect-throw "ALREADY_IN_USE": rmt.Channel pin --input
  channels.do: it.close
  // Now that we closed all channels we are again OK to get one.
  channel = rmt.Channel pin --input
  channel.close

  // Test fragmentation.
  channels = []
  8.repeat: channels.add (rmt.Channel pin --input)
  for i := 0; i < channels.size; i += 2: channels[i].close
  expect-throw "ALREADY_IN_USE": rmt.Channel pin --memory-block-count=2 --input
  // Close one additional one, which makes 2 adjacent memory blocks free.
  channels[5].close
  channel = rmt.Channel pin --memory-block-count=2 --input
  channel.close
  channels.do: it.close

  // Test specific IDs.
  channel1 := rmt.Channel pin --channel-id=1 --input
  channel0 := rmt.Channel pin --channel-id=0 --input
  expect-throw "ALREADY_IN_USE": rmt.Channel pin --memory-block-count=7 --input
  channel1.close
  channel = rmt.Channel pin --memory-block-count=7 --input
  channel.close

in-parallel fun1/Lambda fun2/Lambda:
  ready-semaphore := monitor.Semaphore
  done-semaphore := monitor.Semaphore
  task::
    fun1.call
        :: ready-semaphore.down
        :: done-semaphore.up

  fun2.call:: ready-semaphore.up
  done-semaphore.down

test-simple-pulse pin-in/gpio.Pin pin-out/gpio.Pin:
  PULSE-LENGTH ::= 50

  in-parallel
    :: | wait-for-ready done |
      wait-for-ready.call
      out := rmt.Channel pin-out --output --idle-level=0
      signals := rmt.Signals 1
      signals.set 0 --level=1 --period=PULSE-LENGTH
      out.write signals
      out.close
      done.call
    :: | ready |
      in := rmt.Channel pin-in --input --idle-threshold=120
      in.start-reading
      ready.call
      signals := in.read
      in.stop-reading
      in.close
      expect (signals.size == 1 or signals.size == 2)
      expect (PULSE-LENGTH - (signals.period 0)).abs <= SLACK
      if signals.size == 2: expect-equals 0 (signals.period 1)

test-multiple-pulses pin-in/gpio.Pin pin-out/gpio.Pin:
  PULSE-LENGTH ::= 50
  // It's important that the count is odd, as we would otherwise end
  // low. The receiving end would not be able to see the last signal.
  SIGNAL-COUNT ::= 11

  in-parallel
    :: | wait-for-ready done |
      wait-for-ready.call
      out := rmt.Channel pin-out --output --idle-level=0
      signals := rmt.Signals.alternating SIGNAL-COUNT --first-level=1: PULSE-LENGTH
      signals.set 0 --level=1 --period=PULSE-LENGTH
      out.write signals
      out.close
      done.call
    :: | ready |
      in := rmt.Channel pin-in --input --idle-threshold=120
      in.start-reading
      ready.call
      signals := in.read
      in.stop-reading
      in.close
      expect signals.size >= SIGNAL-COUNT
      SIGNAL-COUNT.repeat:
        expect (PULSE-LENGTH - (signals.period it)).abs <= SLACK
      for i := SIGNAL-COUNT; i < signals.size; i++:
        expect-equals 0 (signals.period i)

test-long-sequence pin-in/gpio.Pin pin-out/gpio.Pin:
  PULSE-LENGTH ::= 50
  // It's important that the count is odd, as we would otherwise end
  // low. The receiving end would not be able to see the last signal.
  // One memory block supports 128 signals. We allocate 6 of them.
  // It seems like we need to reserve 2 signals. Not completely clear why, but good enough.
  SIGNAL-COUNT ::= 128 * 6

  in-parallel
    :: | wait-for-ready done |
      wait-for-ready.call
      out := rmt.Channel pin-out --output --idle-level=0
      signals := rmt.Signals.alternating SIGNAL-COUNT --first-level=1: PULSE-LENGTH
      signals.set 0 --level=1 --period=PULSE-LENGTH
      out.write signals
      out.close
      done.call
    :: | ready |
      // Note that we need a second memory block as the internal buffer would otherwise
      // overflow. On the serial port we would see the following message:
      // E (726) rmt: RMT RX BUFFER FULL
      // We also need to have enough space in the buffer. Otherwise we get the same error.

      // 2 bytes per signal. Twice for the ring-buffer. And some extra for bookkeeping.
      buffer-size := SIGNAL-COUNT * 2 * 2 + 20
      in := rmt.Channel pin-in --input --idle-threshold=120 --memory-block-count=6 --buffer-size=buffer-size
      in.start-reading
      ready.call
      signals := in.read
      in.stop-reading
      in.close
      expect signals.size >= SIGNAL-COUNT
      (SIGNAL-COUNT - 1).repeat:
        expect (PULSE-LENGTH - (signals.period it)).abs <= SLACK
      for i := SIGNAL-COUNT; i < signals.size; i++:
        expect-equals 0 (signals.period i)

test-bidirectional pin1/gpio.Pin pin2/gpio.Pin:
  // Use pin3 as pull-up pin.
  pin3 := gpio.Pin RMT-PIN-3 --pull-up --input

  PULSE-LENGTH ::= 50

  in-parallel
    :: | wait-for-ready done |
      out := rmt.Channel pin1 --output --idle-level=1
      in := rmt.Channel pin1 --input
      // We actually don't need the bidirectionality here, but by
      // making the channel bidirectional it switches to open drain.
      rmt.Channel.make-bidirectional --in=in --out=out

      // Do a lot of signals.
      signals := rmt.Signals.alternating 100 --first-level=1: 10
      for i := 5; i < 100; i += 10:
        // Let some of the signals be a bit longer, so that the receiver
        // can see at least some of our signals.
        signals.set i --level=0 --period=1_300
        signals.set i+1 --level=1 --period=1_300
      wait-for-ready.call
      out.write signals
      in.close
      out.close
      done.call

    :: | ready |
      out := rmt.Channel pin2 --output --idle-level=1
      in := rmt.Channel pin2 --input --idle-threshold=5_000 --memory-block-count=4
      rmt.Channel.make-bidirectional --in=in --out=out

      signals := rmt.Signals.alternating 100 --first-level=0: 1_000
      // Trigger the idle_threshold by pulling the 99th level low for more than 5_000us.
      signals.set 99 --level=0 --period=6_000
      /**
      // Here is a good moment to reset the trigger on the oscilloscope.
      print "high"
      sleep --ms=2_000
      */
      in.start-reading
      ready.call // Overlap the signals from the other pin.
      out.write signals
      in-signals := in.read
      in.stop-reading
      in.close
      out.close
      // We expect to see the 10us pulses from the other pin.
      // At the same time we want to see 1000us pulses from our pin.
      saw-10us := false
      saw-1000us := false
      for i := 0; i < in-signals.size; i++:
        if ((in-signals.period i) - 10).abs < SLACK: saw-10us = true
        if ((in-signals.period i) - 1000).abs < SLACK: saw-1000us = true
        if saw-10us and saw-1000us: break
      expect (saw-10us and saw-1000us)

  pin3.close

test-multiple-sequences pin-in/gpio.Pin pin-out/gpio.Pin:
  PULSE-LENGTH ::= 50
  IDLE-LENGTH ::= 100
  SIGNAL-COUNT ::= 13

  out := rmt.Channel pin-out --output --idle-level=0
  in := rmt.Channel pin-in --input --idle-threshold=IDLE-LENGTH

  // Local block to compute the pulse-length for the x'th signal.
  pulse-length-for := : | signal-id |
    result := PULSE-LENGTH + signal-id * 2
    expect result < IDLE-LENGTH
    result

  check-signal-sequence := : | signals sequence-id |
    expect 1 <= signals.size <= 2
    expect-equals 1 (signals.level 0)
    expect ((signals.period 0) - (pulse-length-for.call (sequence-id * 2))).abs <= SLACK
    if signals.size == 2: expect-equals 0 (signals.period 1)

  out-signals := rmt.Signals SIGNAL-COUNT
  up := true
  SIGNAL-COUNT.repeat:
    if up:
      up = false
      out-signals.set it --level=1 --period=(pulse-length-for.call it)
    else:
      up = true
      // Trigger an idle for the input.
      out-signals.set it --level=0 --period=(IDLE-LENGTH * 2)

  // Start reading, then write all the signals.
  // They should be buffered and readable.
  in.start-reading
  out.write out-signals
  (SIGNAL-COUNT / 2).repeat:
    in-signals := in.read
    check-signal-sequence.call in-signals it
  in.stop-reading

  // Start reading, then write all the signals.
  // Stop reading, then read them one by one by starting again and stopping for each.
  // It's crucial we don't flush the buffer when starting now.
  in.start-reading
  out.write out-signals
  (SIGNAL-COUNT / 2).repeat:
    if not in.is-reading:
      in.start-reading --no-flush
    in-signals := in.read
    in.stop-reading
    check-signal-sequence.call in-signals it
  in.stop-reading

  // Start reading, then write all the signals. Stop reading.
  // Start reading again, flushing the buffer, then write (in parallel).
  // We should only see the new data.
  in.start-reading
  out.write out-signals
  in.stop-reading
  SECOND-PULSE-PERIOD ::= 13
  in-parallel
    :: | wait-for-ready done |
      wait-for-ready.call
      sleep --ms=200
      second-out-signals := rmt.Signals 1
      second-out-signals.set 0 --level=1 --period=SECOND-PULSE-PERIOD
      out.write second-out-signals
      done.call
    :: | ready |
      ready.call
      in-signals := in.read
      expect 1 <= in-signals.size <= 2
      expect-equals 1 (in-signals.level 0)
      expect ((in-signals.period 0) - SECOND-PULSE-PERIOD).abs <= SLACK
      if in-signals.size == 2: expect-equals 0 (in-signals.period 1)

  in.close
  out.close

main:
  run-test: test

test:
  pin1 := gpio.Pin RMT-PIN-1
  pin2 := gpio.Pin RMT-PIN-2

  test-resource pin1

  test-simple-pulse pin1 pin2
  test-multiple-pulses pin1 pin2
  test-long-sequence pin1 pin2
  test-bidirectional pin1 pin2
  test-multiple-sequences pin1 pin2

  pin1.close
  pin2.close

  print "all tests done"
