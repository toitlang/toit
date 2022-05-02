// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests a simple pulse from the RMT peripheral.

Setup:
Get two ESP32 boards.
One is the testee and should run the `_testee.toit`.
The other is the tester and should run the equivalent `_tester.toit`.

Connect GND of boath boards.
Connect pin 18 of the tester board to Reset of the testee.
Connect pin 25, 26 and 27 of each board to the other. (3 parallel lines).
*/

import rmt
import gpio
import expect show *

TESTER_RMT_PIN ::= 25
TESTEE_RMT_PIN ::= 25

TESTER_IN_PIN ::= 26
TESTER_OUT_PIN ::= 27
TESTEE_IN_PIN ::= 27
TESTEE_OUT_PIN ::= 26

TESTER_RESET_OUT_PIN ::= 18

class Control:
  in /gpio.Pin
  out /gpio.Pin

  constructor --.in --.out:
    in.config --input
    out.config --output

  sync:
    print "Waiting for sync"
    out.set 1
    in.wait_for 1
    sleep --ms=50
    out.set 0
    print "Synched"

  wait_for value/int:
    in.wait_for value

  set value/int:
    out.set value

reset_testee:
  reset := gpio.Pin TESTER_RESET_OUT_PIN --output
  reset.set 0
  sleep --ms=100
  reset.set 1
  reset.close


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



test_simple_pulse control/Control rmt_pin/gpio.Pin --tester/bool=false:
  PULSE_LENGTH ::= 100
  if tester:
    channel := rmt.Channel rmt_pin --input
    sleep --ms=20
    control.set 1
    signals := channel.read 16 --timeout_ms=500
    expect_equals 6 signals.size
    for i := 0; i < 6; i++:
      expect (PULSE_LENGTH - (signals.period i)).abs < 3
      expect_equals ((i + 1) % 2) (signals.level i)
    control.set 0
    channel.close
    print "test done"
    return

  channel := rmt.Channel rmt_pin --output
  signals := rmt.Signals.alternating 6 --first_level=1: PULSE_LENGTH
  control.wait_for 1
  sleep --ms=10
  channel.write signals
  sleep --ms=100
  print "Closing channel"
  channel.close

/**
Runs the tester.
*/
run_tester:
  reset_testee
  control := Control --in=(gpio.Pin TESTER_IN_PIN) --out=(gpio.Pin TESTER_OUT_PIN)
  control.sync
  rmt_pin := gpio.Pin TESTER_RMT_PIN
  test_simple_pulse control rmt_pin --tester
  control.sync

/**
Runs the testee.
*/
run_testee:
  control := Control --in=(gpio.Pin TESTEE_IN_PIN) --out=(gpio.Pin TESTEE_OUT_PIN)
  rmt_pin := gpio.Pin TESTEE_RMT_PIN

  test_resource rmt_pin

  control.sync
  test_simple_pulse control rmt_pin
  control.sync
