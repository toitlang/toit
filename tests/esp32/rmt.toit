// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests a simple pulse from the RMT peripheral.

Setup:
Connect pin 18 and 19 with a 330 Ohm resistor. The resistor isn't
  strictly necessary but can prevent accidental short circuiting.

Similarly, connect pin 15 to pin 19 with a 330 Ohm resistor. We will
  use that one to pull the line high.
*/

import rmt
import gpio
import monitor
import expect show *

RMT_PIN_1 ::= 18
RMT_PIN_2 ::= 19
RMT_PIN_3 ::= 15

// Because of the resistors we use the reading isn't fully precise.
// We allow 5us error.
SLACK ::= 5

// Test that the channel resources are correctly handed out.
test_resource pin/gpio.Pin:
  // There are 8 channels, each having one memory block.
  // If we request a channel with more than one memory block, then the
  // next channel becomes unusable.
  channels := []
  8.repeat: channels.add (rmt.Channel pin)
  expect_throw "ALREADY_IN_USE": rmt.Channel pin
  channels.do: it.close
  // Now that we closed all channels we are again OK to get one.
  channel := rmt.Channel pin
  channel.close

  channels = []
  // We should be able to allocate 4 channels with 2 memory blocks.
  4.repeat: channels.add (rmt.Channel pin --memory_block_count=2)
  expect_throw "ALREADY_IN_USE": rmt.Channel pin
  channels.do: it.close
  // Now that we closed all channels we are again OK to get one.
  channel = rmt.Channel pin
  channel.close

  channels = []
  // We should be able to allocate 2 channels with 3 memory blocks, and one with 2
  2.repeat: channels.add (rmt.Channel pin --memory_block_count=3)
  channels.add (rmt.Channel pin --memory_block_count=2)
  expect_throw "ALREADY_IN_USE": rmt.Channel pin
  channels.do: it.close
  // Now that we closed all channels we are again OK to get one.
  channel = rmt.Channel pin
  channel.close

  channels = []
  // We should be able to allocate 2 channels with 4 memory blocks.
  2.repeat: channels.add (rmt.Channel pin --memory_block_count=4)
  expect_throw "ALREADY_IN_USE": rmt.Channel pin
  channels.do: it.close
  // Now that we closed all channels we are again OK to get one.
  channel = rmt.Channel pin
  channel.close

  // Test fragmentation.
  channels = []
  8.repeat: channels.add (rmt.Channel pin)
  for i := 0; i < channels.size; i += 2: channels[i].close
  expect_throw "ALREADY_IN_USE": rmt.Channel pin --memory_block_count=2
  // Close one additional one, which makes 2 adjacent memory blocks free.
  channels[5].close
  channel = rmt.Channel pin --memory_block_count=2
  channel.close
  channels.do: it.close

  // Test specific IDs.
  channel1 := rmt.Channel pin --channel_id=1
  channel0 := rmt.Channel pin --channel_id=0
  expect_throw "ALREADY_IN_USE": rmt.Channel pin --memory_block_count=7
  channel1.close
  channel = rmt.Channel pin --memory_block_count=7
  channel.close

in_parallel fun1/Lambda fun2/Lambda:
  ready_semaphore := monitor.Semaphore
  done_semaphore := monitor.Semaphore
  task::
    fun1.call
        :: ready_semaphore.down
        :: done_semaphore.up

  fun2.call:: ready_semaphore.up
  done_semaphore.down

test_simple_pulse pin_in/gpio.Pin pin_out/gpio.Pin:
  PULSE_LENGTH ::= 50

  in_parallel
    :: | wait_for_ready done |
      wait_for_ready.call
      out := rmt.Channel pin_out --output --idle_level=0
      signals := rmt.Signals 1
      signals.set 0 --level=1 --period=PULSE_LENGTH
      out.write signals
      out.close
      done.call
    :: | ready |
      in := rmt.Channel pin_in --input --idle_threshold=120
      in.start_reading
      ready.call
      signals := in.read
      in.stop_reading
      in.close
      expect (signals.size == 1 or signals.size == 2)
      expect (PULSE_LENGTH - (signals.period 0)).abs <= SLACK
      if signals.size == 2: expect_equals 0 (signals.period 1)

test_multiple_pulses pin_in/gpio.Pin pin_out/gpio.Pin:
  PULSE_LENGTH ::= 50
  // It's important that the count is odd, as we would otherwise end
  // low. The receiving end would not be able to see the last signal.
  SIGNAL_COUNT ::= 11

  in_parallel
    :: | wait_for_ready done |
      wait_for_ready.call
      out := rmt.Channel pin_out --output --idle_level=0
      signals := rmt.Signals.alternating SIGNAL_COUNT --first_level=1: PULSE_LENGTH
      signals.set 0 --level=1 --period=PULSE_LENGTH
      out.write signals
      out.close
      done.call
    :: | ready |
      in := rmt.Channel pin_in --input --idle_threshold=120
      in.start_reading
      ready.call
      signals := in.read
      in.stop_reading
      in.close
      expect signals.size >= SIGNAL_COUNT
      SIGNAL_COUNT.repeat:
        expect (PULSE_LENGTH - (signals.period it)).abs <= SLACK
      for i := SIGNAL_COUNT; i < signals.size; i++:
        expect_equals 0 (signals.period i)

test_long_sequence pin_in/gpio.Pin pin_out/gpio.Pin:
  PULSE_LENGTH ::= 50
  // It's important that the count is odd, as we would otherwise end
  // low. The receiving end would not be able to see the last signal.
  // One memory block supports 128 signals. We allocate 6 of them.
  // It seems like we need to reserve 2 signals. Not completely clear why, but good enough.
  SIGNAL_COUNT ::= 128 * 6

  in_parallel
    :: | wait_for_ready done |
      wait_for_ready.call
      out := rmt.Channel pin_out --output --idle_level=0
      signals := rmt.Signals.alternating SIGNAL_COUNT --first_level=1: PULSE_LENGTH
      signals.set 0 --level=1 --period=PULSE_LENGTH
      out.write signals
      out.close
      done.call
    :: | ready |
      // Note that we need a second memory block as the internal buffer would otherwise
      // overflow. On the serial port we would see the following message:
      // E (726) rmt: RMT RX BUFFER FULL
      // We also need to have enough space in the buffer. Otherwise we get the same error.

      // 2 bytes per signal. Twice for the ring-buffer. And some extra for bookkeeping.
      buffer_size := SIGNAL_COUNT * 2 * 2 + 20
      in := rmt.Channel pin_in --input --idle_threshold=120 --memory_block_count=6 --buffer_size=buffer_size
      in.start_reading
      ready.call
      signals := in.read
      in.stop_reading
      in.close
      expect signals.size >= SIGNAL_COUNT
      (SIGNAL_COUNT - 1).repeat:
        expect (PULSE_LENGTH - (signals.period it)).abs <= SLACK
      for i := SIGNAL_COUNT; i < signals.size; i++:
        expect_equals 0 (signals.period i)

test_bidirectional pin1/gpio.Pin pin2/gpio.Pin:
  // Use pin3 as pull-up pin.
  pin3 := gpio.Pin RMT_PIN_3 --pull_up --input

  PULSE_LENGTH ::= 50

  in_parallel
    :: | wait_for_ready done |
      out := rmt.Channel pin1 --output --idle_level=1
      in := rmt.Channel pin1 --input
      // We actually don't need the bidirectionality here, but by
      // making the channel bidirectional it switches to open drain.
      rmt.Channel.make_bidirectional --in=in --out=out

      // Do a lot of signals.
      signals := rmt.Signals.alternating 100 --first_level=1: 10
      for i := 5; i < 100; i += 10:
        // Let some of the signals be a bit longer, so that the receiver
        // can see at least some of our signals.
        signals.set i --level=0 --period=1_300
        signals.set i+1 --level=1 --period=1_300
      wait_for_ready.call
      out.write signals
      in.close
      out.close
      done.call

    :: | ready |
      out := rmt.Channel pin2 --output --idle_level=1
      in := rmt.Channel pin2 --input --idle_threshold=5_000 --memory_block_count=4
      rmt.Channel.make_bidirectional --in=in --out=out

      signals := rmt.Signals.alternating 100 --first_level=0: 1_000
      // Trigger the idle_threshold by pulling the 99th level low for more than 5_000us.
      signals.set 99 --level=0 --period=6_000
      /**
      // Here is a good moment to reset the trigger on the oscilloscope.
      print "high"
      sleep --ms=2_000
      */
      in.start_reading
      ready.call // Overlap the signals from the other pin.
      out.write signals
      in_signals := in.read
      in.stop_reading
      in.close
      out.close
      // We expect to see the 10us pulses from the other pin.
      // At the same time we want to see 1000us pulses from our pin.
      saw_10us := false
      saw_1000us := false
      for i := 0; i < in_signals.size; i++:
        if ((in_signals.period i) - 10).abs < SLACK: saw_10us = true
        if ((in_signals.period i) - 1000).abs < SLACK: saw_1000us = true
        if saw_10us and saw_1000us: break
      expect (saw_10us and saw_1000us)

  pin3.close

main:
  pin1 := gpio.Pin RMT_PIN_1
  pin2 := gpio.Pin RMT_PIN_2

  test_resource pin1

  test_simple_pulse pin1 pin2
  test_multiple_pulses pin1 pin2
  test_long_sequence pin1 pin2
  test_bidirectional pin1 pin2

  pin1.close
  pin2.close

  print "all tests done"
