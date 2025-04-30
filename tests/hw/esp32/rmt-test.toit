// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests a simple pulse from the RMT peripheral.

For the setup see the comment near $Variant.rmt-pin1.
*/

import expect show *
import gpio
import monitor
import pulse-counter
import rmt
import system

import .test
import .variants

RMT-PIN-1 ::= Variant.CURRENT.rmt-pin1
RMT-PIN-2 ::= Variant.CURRENT.rmt-pin2
RMT-PIN-3 ::= Variant.CURRENT.rmt-pin3

IN-CHANNEL-COUNT ::= Variant.CURRENT.rmt-in-channel-count
OUT-CHANNEL-COUNT ::= Variant.CURRENT.rmt-out-channel-count
TOTAL-CHANNEL-COUNT ::= Variant.CURRENT.rmt-total-channel-count

// Because of the resistors and a weak pull-up, the reading isn't fully precise.
// We allow 5us error.
SLACK ::= 5

RESOLUTION ::= 1_000_000  // 1MHz.

// Test that the channel resources are correctly handed out.
test-resource pin/gpio.Pin:
  // There are 8 channels, each having one memory block.
  // If we request a channel with more than one memory block, then the
  // next channel becomes unusable.
  channels := []
  IN-CHANNEL-COUNT.repeat: channels.add (rmt.In pin --resolution=RESOLUTION)
  if IN-CHANNEL-COUNT != TOTAL-CHANNEL-COUNT:
    OUT-CHANNEL-COUNT.repeat:
      channels.add (rmt.Out pin --resolution=RESOLUTION)
  expect-throw "ALREADY_IN_USE": rmt.In pin --resolution=RESOLUTION
  channels.do: it.close
  // Now that we closed all channels we are again OK to get one.
  channel := rmt.In pin --resolution=RESOLUTION
  channel.close

  channels = []
  // We should be able to allocate half of the channels with 2 memory blocks each.
  (IN-CHANNEL-COUNT / 2).repeat: channels.add (rmt.In pin --resolution=RESOLUTION --memory-blocks=2)
  expect-throw "ALREADY_IN_USE": rmt.In pin --resolution=RESOLUTION
  channels.do: it.close
  // Now that we closed all channels we are again OK to get one.
  channel = rmt.In pin --resolution=RESOLUTION
  channel.close

  channels = []
  // We should be able to allocate at least on channel with 3 memory blocks.
  // If there are more than 4 in channels, we should be able to allocate two.
  channels.add (rmt.In pin --resolution=RESOLUTION --memory-blocks=3)
  if IN-CHANNEL-COUNT > 4:
    channels.add (rmt.In pin --resolution=RESOLUTION --memory-blocks=3)
    channels.add (rmt.In pin --resolution=RESOLUTION --memory-blocks=2)
  else:
    channels.add (rmt.In pin --resolution=RESOLUTION --memory-blocks=1)
  expect-throw "ALREADY_IN_USE": rmt.In pin --resolution=RESOLUTION
  channels.do: it.close
  // Now that we closed all channels we are again OK to get one.
  channel = rmt.In pin --resolution=RESOLUTION
  channel.close

  channels = []
  // We should be able to allocate at least one channel with 4 memory blocks.
  // If we have more than 4 in channels, we should be able to allocate two.
  channels.add (rmt.In pin --resolution=RESOLUTION --memory-blocks=4)
  if IN-CHANNEL-COUNT > 4:
    channels.add (rmt.In pin --resolution=RESOLUTION --memory-blocks=4)
  expect-throw "ALREADY_IN_USE": rmt.In pin --resolution=RESOLUTION
  channels.do: it.close
  // Now that we closed all channels we are again OK to get one.
  channel = rmt.In pin --resolution=RESOLUTION
  channel.close

  // Test fragmentation.
  channels = []
  IN-CHANNEL-COUNT.repeat: channels.add (rmt.In pin --resolution=RESOLUTION)
  for i := 0; i < channels.size; i += 2: channels[i].close
  expect-throw "ALREADY_IN_USE": rmt.In pin --resolution=RESOLUTION --memory-blocks=2
  // Close one additional one, which makes 2 adjacent memory blocks free.
  channels[IN-CHANNEL-COUNT / 2 + 1].close
  channel = rmt.In pin --resolution=RESOLUTION --memory-blocks=2
  channel.close
  channels.do: it.close

test-simple-pulse pin-in/gpio.Pin pin-out/gpio.Pin:
  PULSE-LENGTH ::= 50

  out := rmt.Out pin-out --resolution=RESOLUTION
  in := rmt.In pin-in --resolution=RESOLUTION
  in.start-reading --min-ns=1 --max-ns=(120 * 1000)
  out-signals := rmt.Signals 1
  out-signals.set 0 --level=1 --period=PULSE-LENGTH
  out.write out-signals --done-level=0
  in-signals := in.wait-for-data
  expect-equals 2 in-signals.size
  expect (PULSE-LENGTH - (in-signals.period 0)).abs <= SLACK
  expect-equals 0 (in-signals.period 1)
  out.close
  in.close


test-multiple-pulses pin-in/gpio.Pin pin-out/gpio.Pin:
  PULSE-LENGTH ::= 50
  // It's important that the count is odd, as we would otherwise end
  // low. The receiving end would not be able to see the last signal.
  SIGNAL-COUNT ::= 11

  out := rmt.Out pin-out --resolution=RESOLUTION
  in := rmt.In pin-in --resolution=RESOLUTION
  in.start-reading --min-ns=1 --max-ns=(120 * 1000)
  out-signals := rmt.Signals.alternating SIGNAL-COUNT --first-level=1: PULSE-LENGTH
  out-signals.set 0 --level=1 --period=PULSE-LENGTH
  out.write out-signals --done-level=0
  in-signals := in.wait-for-data
  expect-equals (SIGNAL-COUNT + 1) in-signals.size
  SIGNAL-COUNT.repeat:
    expect (PULSE-LENGTH - (in-signals.period it)).abs <= SLACK
  expect-equals 0 (in-signals.period (in-signals.size - 1))
  out.close
  in.close

test-long-sequence pin-in/gpio.Pin pin-out/gpio.Pin:
  PULSE-LENGTH ::= 50
  MEMORY-BLOCKS ::= IN-CHANNEL-COUNT == TOTAL-CHANNEL-COUNT
      ? IN-CHANNEL-COUNT - 1
      : IN-CHANNEL-COUNT
  SIGNAL-COUNT ::= ((rmt.BYTES-PER-MEMORY-BLOCK * MEMORY-BLOCKS) - 1) / 2

  out := rmt.Out pin-out --resolution=RESOLUTION
  in := rmt.In pin-in --memory-blocks=MEMORY-BLOCKS --resolution=RESOLUTION
  in.start-reading --min-ns=1 --max-ns=(120 * 1000)
  out-signals := rmt.Signals.alternating SIGNAL-COUNT --first-level=1: PULSE-LENGTH
  out-signals.set 0 --level=1 --period=PULSE-LENGTH
  out.write out-signals --done-level=0
  // Note that the ESP-IDF reports a "buffer too small" error. This is actually not true,
  // since the data fits. However, it uses up all the space, and the ESP-IDF doesn't seem to
  // cover that corner case.
  in-signals := in.wait-for-data
  expect in-signals.size >= SIGNAL-COUNT
  (SIGNAL-COUNT - 1).repeat:
    expect (PULSE-LENGTH - (in-signals.period it)).abs <= SLACK
  expect-equals 0 (in-signals.period (in-signals.size - 1))
  out.close
  in.close

test-carrier pin1/gpio.Pin pin2/gpio.Pin:
  test-carrier pin1 pin2 --duty-factor=0.5 --active-low
  test-carrier pin1 pin2 --duty-factor=0.5
  test-carrier pin1 pin2 --duty-factor=0.25
  if system.architecture != system.ARCHITECTURE-ESP32:
    // The ESP32 doesn't support demodulation.
    test-carrier pin1 pin2 --duty-factor=0.5 --demodulate
    test-carrier pin1 pin2 --duty-factor=0.5 --active-low --demodulate

    test-carrier pin1 pin2 --always-on

test-carrier pin1/gpio.Pin pin2/gpio.Pin
    --duty-factor/float
    --active-low/bool=false
    --demodulate/bool=false:
  CARRIER-FREQUENCY ::= 5_000
  CARRIER-PERIOD ::= 1_000_000  / CARRIER_FREQUENCY
  SIGNAL-PERIOD ::= 1_000
  DONE-PERIOD ::= SIGNAL-PERIOD * 2
  DONE-NS ::= 1_000_000_000 * DONE-PERIOD / RESOLUTION
  UP-TICKS ::= (CARRIER-PERIOD * duty-factor).to-int
  DOWN-TICKS ::= CARRIER-PERIOD - UP-TICKS
  UP-NS ::= (1_000_000_000 / CARRIER-FREQUENCY * duty-factor).to-int
  DOWN-NS ::= (1_000_000_000 / CARRIER-FREQUENCY * (1 - duty-factor)).to-int

  out := rmt.Out pin1 --resolution=RESOLUTION
  out.apply-carrier CARRIER-FREQUENCY --duty-factor=duty-factor --active-low=active-low

  // The ESP32 applies the carrier even to the idle level.
  // Set the current idle level to the opposite of the active level, so we don't
  // have the carrier when we are not sending.
  no-signals := rmt.Signals 1
  no-signals.set 0 --level=0 --period=0
  out.write no-signals --done-level=(active-low ? 1 : 0)

  in := rmt.In pin2 --resolution=RESOLUTION
  if demodulate:
    in-carrier-frequency := CARRIER-FREQUENCY * 2 / 3
    in.apply-carrier in-carrier-frequency --duty-factor=duty-factor --active-low=active-low

  in.start-reading --min-ns=0 --max-ns=DONE-NS
  MODULATED-SIGNALS ::= 3
  out-signals := rmt.Signals.alternating (MODULATED-SIGNALS * 2) --first-level=1: SIGNAL-PERIOD
  done-level := active-low ? 1 : 0
  out.write out-signals --done-level=done-level
  in-signals := in.wait-for-data
  out.close
  in.close

  if demodulate:
    // We don't expect to see the carrier, but only the signal.
    size := in-signals.size
    expect (size == 5 or size == 6)
    if size == 6: expect-equals 0 (in-signals.period 5)
    expected-level := active-low ? 0 : 1
    5.repeat:
      expect-equals expected-level (in-signals.level it)
      expected-level = 1 - expected-level
    for i := 0; i < 5; i++:
      period := in-signals.period i
      slack := 2 * (max UP-TICKS DOWN-TICKS) + SLACK
      expect (period - SIGNAL-PERIOD).abs < slack
    return

  carrier-high-count := 0  // Carrier high.
  shorter-carrier-high-count := 0  // Carrier high, but shorter than expected.
  signal-high-count := 0  // Signal high, but no carrier.

  carrier-low-count := 0
  shorter-carrier-low-count := 0
  signal-low-count := 0

  sum := 0
  in-signals.do: | level/int period/int |
    sum += period
    if period == 0:
      continue.do

    if level == 1:
      if (period - UP-TICKS).abs <= SLACK:
        carrier-high-count++
      else if period < UP-TICKS - SLACK:
        shorter-carrier-high-count++
      else if period > UP-TICKS + SLACK:
        signal-high-count++
      else:
        throw "Unexpected signal $level - $period"
    else:
      if (period - DOWN-TICKS).abs <= SLACK:
        carrier-low-count++
      else if period < DOWN-TICKS - SLACK:
        shorter-carrier-low-count++
      else if period > DOWN-TICKS + SLACK:
        signal-low-count++
      else:
        throw "Unexpected signal $level - $period"

  // At the beginning and end of signals the carrier might be cut off.
  // Shouldn't happen often.
  max-shorter := MODULATED-SIGNALS * 2
  expect shorter-carrier-low-count <= max-shorter
  expect shorter-carrier-high-count <= max-shorter
  expect sum > 5 * SIGNAL-PERIOD - SLACK - 2 * (max UP-TICKS DOWN-TICKS)
  if active-low:
    expect-equals 2 signal-high-count
    expect-equals 0 signal-low-count
    expect carrier-high-count >= MODULATED-SIGNALS * (SIGNAL-PERIOD / CARRIER-PERIOD - 1)
    expect carrier-low-count >= MODULATED-SIGNALS * (SIGNAL-PERIOD / CARRIER-PERIOD - 1)
  else:
    expect-equals 0 signal-high-count
    expect-equals 2 signal-low-count
    expect carrier-high-count >= (SIGNAL-PERIOD * 2) / CARRIER-PERIOD
    expect carrier-low-count >= SIGNAL-PERIOD / CARRIER-PERIOD - 2

test-carrier pin1/gpio.Pin pin2/gpio.Pin --always-on/True:
  CARRIER-FREQUENCY ::= 5_000
  CARRIER-PERIOD ::= 1_000_000  / CARRIER_FREQUENCY
  SIGNAL-PERIOD ::= 1_000
  DONE-PERIOD ::= SIGNAL-PERIOD * 2
  DONE-NS ::= 1_000_000_000 * DONE-PERIOD / RESOLUTION
  CARRIER-TO-SIGNAL-RATIO ::= SIGNAL-PERIOD / CARRIER-PERIOD

  out := rmt.Out pin1 --resolution=RESOLUTION
  out.apply-carrier CARRIER-FREQUENCY --duty-factor=0.5 --always-on

  in := rmt.In pin2 --resolution=RESOLUTION --memory-blocks=IN-CHANNEL-COUNT

  in.start-reading --min-ns=0 --max-ns=DONE-NS
  out-signals := rmt.Signals 2
  out-signals.set 0 --level=1 --period=SIGNAL-PERIOD
  out-signals.set 1 --level=0 --period=SIGNAL-PERIOD
  out.write out-signals --done-level=0
  in-signals := in.wait-for-data

  // Since we finished with the done-level at 0, the 'always-on' doesn't have any effect.
  expect CARRIER-TO-SIGNAL-RATIO * 2 - 2 <= in-signals.size <= CARRIER-TO-SIGNAL-RATIO * 2 + 2

  in.start-reading --min-ns=0 --max-ns=DONE-NS
  // Now do the same, but with a done-level at 1.
  no-signal := rmt.Signals 1
  no-signal.set 0 --level=0 --period=0

  out.write out-signals --done-level=1
  sleep --ms=10
  // We might get a "user buffer too small" in the reader if we are not fast enough to write
  // the 'no-signal'. But that's ok.
  out.write no-signal --done-level=0

  in-signals = in.wait-for-data

  expect in-signals.size > CARRIER-TO-SIGNAL-RATIO * 2 + 2

  out.close
  in.close

test-glitch-filter pin1/gpio.Pin pin2/gpio.Pin:
  out := rmt.Out pin1 --resolution=RESOLUTION
  in := rmt.In pin2 --resolution=RESOLUTION

  GLITCH-PERIOD ::= 1
  GLITCH-NS ::= GLITCH-PERIOD * 1_000
  SIGNAL-PERIOD ::= 80

  in.start-reading --min-ns=(2 * GLITCH-NS) --max-ns=(SIGNAL-PERIOD * 2 * 1000)

  signals := rmt.Signals 4
  signals.set 0 --level=1 --period=GLITCH-PERIOD  // Should be glitch-filtered.
  signals.set 1 --level=0 --period=SIGNAL-PERIOD  // Should be merged with the idle level.
  signals.set 2 --level=1 --period=SIGNAL-PERIOD
  signals.set 3 --level=0 --period=0
  out.write signals --done-level=0

  received := in.wait-for-data

  expect (received.size == 1 or received.size == 2)
  if received.size == 2: expect-equals 0 (received.period 1)
  level := received.level 0
  period := received.period 0
  expect-equals 1 level
  expect (period - SIGNAL-PERIOD).abs <= SLACK

  in.close
  out.close

test-bidirectional pin1/gpio.Pin pin2/gpio.Pin:
  // Use pin3 as pull-up pin.
  pin3 := gpio.Pin RMT-PIN-3 --pull-up --input

  PULSE-LENGTH ::= 50

  in1 := rmt.In pin1 --resolution=RESOLUTION --memory-blocks=1
  in2 := rmt.In pin2 --resolution=RESOLUTION --memory-blocks=2

  out1 := rmt.Out pin1 --resolution=RESOLUTION --open-drain
  out2 := rmt.Out pin2 --resolution=RESOLUTION --open-drain

  // Do a lot of signals.
  out-signals1 := rmt.Signals.alternating 100 --first-level=1: 10
  for i := 5; i < 100; i += 10:
    // Let some of the signals be a bit longer, so that the receiver
    // can see at least some of our signals.
    out-signals1.set i --level=0 --period=1_300
    out-signals1.set i+1 --level=1 --period=1_300

  out-signals2 := rmt.Signals.alternating 100 --first-level=0: 1_000
  // Trigger the idle_threshold by pulling the 99th level low for more than 5_000us.
  out-signals2.set 99 --level=0 --period=6_000

  /**
  // Here is a good moment to reset the trigger on the oscilloscope.
  print "high"
  sleep --ms=2_000
  */
  in2.start-reading --min-ns=1 --max-ns=(5000 * 1000)

  out1.write out-signals1 --done-level=1 --no-flush
  out2.write out-signals2 --done-level=1 --no-flush

  in-signals2 := in2.wait-for-data

  // We expect to see the 10us pulses from the other pin.
  // At the same time we want to see 1000us pulses from our pin.
  saw-10us := false
  saw-1000us := false
  for i := 0; i < in-signals2.size; i++:
    if ((in-signals2.period i) - 10).abs < SLACK: saw-10us = true
    if ((in-signals2.period i) - 1000).abs < SLACK: saw-1000us = true
    if saw-10us and saw-1000us: break
  expect (saw-10us and saw-1000us)

  in1.close
  out1.close
  in2.close
  out2.close
  pin3.close

test-loop-count pin1/gpio.Pin pin2/gpio.Pin:
  out := rmt.Out pin1 --resolution=RESOLUTION
  pulse-channel := pulse-counter.Channel pin2
  pulse-unit := pulse-counter.Unit --channels=[pulse-channel]
  pulse-unit.start

  out-signals := rmt.Signals 2
  out-signals.set 0 --level=1 --period=50
  out-signals.set 1 --level=0 --period=50
  out.write out-signals --done-level=0 --loop-count=-1 --no-flush

  while pulse-unit.value < 30:
    yield

  out.reset
  pulse-unit.close

  if system.architecture == system.ARCHITECTURE-ESP32:
    // The ESP32 doesn't support finite loop counts.
    return

  in := rmt.In pin2 --resolution=RESOLUTION
  in.start-reading --min-ns=1 --max-ns=(120 * 1000)

  LOOP-COUNT ::= 4
  out.write out-signals --done-level=0 --loop-count=LOOP-COUNT --no-flush

  in-signals := in.wait-for-data
  expect-equals (LOOP-COUNT * 2) in-signals.size

  in.close
  out.close

test-synchronized-write pin1/gpio.Pin pin2/gpio.Pin:
  if system.architecture == system.ARCHITECTURE-ESP32:
    // The ESP32 doesn't support synchronized writes.
    return

  in := rmt.In pin1 --resolution=RESOLUTION

  idle-signals := rmt.Signals 2
  idle-signals.set 0 --level=1 --period=0
  idle-signals.set 1 --level=1 --period=0
  out1 := rmt.Out pin1 --resolution=RESOLUTION --open-drain --pull-up
  out1.write idle-signals --done-level=1
  out2 := rmt.Out pin2 --resolution=RESOLUTION --open-drain
  out2.write idle-signals --done-level=1

  out-signals1 := rmt.Signals 2
  out-signals1.set 0 --level=0 --period=25
  out-signals1.set 1 --level=1 --period=(83 - 25)

  out-signals2 := rmt.Signals 2
  out-signals2.set 0 --level=1 --period=50
  out-signals2.set 1 --level=0 --period=33

  out1.write out-signals2 --done-level=1
  out2.write out-signals1 --done-level=1

  synchronizer := rmt.SyncManager [out1, out2]

  2.repeat:
    if it == 1: synchronizer.reset

    in.start-reading --min-ns=1 --max-ns=(120 * 1000)
    out1.write out-signals1 --done-level=1 --no-flush
    out2.write out-signals2 --done-level=1

    in-signals := in.wait-for-data
    print in-signals

    expect-equals 4 in-signals.size
    expect-equals 0 (in-signals.level 0)
    expect ((in-signals.period 0) - 25).abs <= SLACK
    expect-equals 1 (in-signals.level 1)
    expect ((in-signals.period 1) - 25).abs <= SLACK
    expect-equals 0 (in-signals.level 2)
    expect ((in-signals.period 2) - 33).abs <= SLACK
    expect-equals 1 (in-signals.level 3)
    expect-equals 0 (in-signals.period 3)

  synchronizer.close
  in.close
  out1.close
  out2.close

main:
  run-test: test

test:
  print "$RMT-PIN-1 <-> $RMT-PIN-2 <-> $RMT-PIN-3"

  pin1 := gpio.Pin RMT-PIN-1
  pin2 := gpio.Pin RMT-PIN-2

  test-resource pin1

  test-simple-pulse pin1 pin2
  test-multiple-pulses pin1 pin2
  test-long-sequence pin1 pin2
  test-carrier pin1 pin2
  test-glitch-filter pin1 pin2
  test-bidirectional pin1 pin2
  test-loop-count pin1 pin2
  test-synchronized-write pin1 pin2

  pin1.close
  pin2.close
