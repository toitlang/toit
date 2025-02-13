// Copyright (C) 2025 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the i2s peripheral.

For the setup see the documentation near $Variant.i2s-data1.
*/

import expect show *
import gpio
import i2s
import monitor
import system

import .i2s-utils
import .test
import .variants

DATA1 ::= Variant.CURRENT.board-connection-pin4
DATA2 ::= Variant.CURRENT.board-connection-pin4

CLK1 ::= Variant.CURRENT.board-connection-pin1
CLK2 ::= Variant.CURRENT.board-connection-pin2

WS1 ::= Variant.CURRENT.board-connection-pin3
WS2 ::= Variant.CURRENT.board-connection-pin3

MCLK1 ::= Variant.CURRENT.board-connection-pin2
MCLK2 ::= Variant.CURRENT.board-connection-pin1

SLOW-SAMPLE-RATE ::= 3_000
FAST-SAMPLE-RATE ::= 70_000

SLOW-DATA-SIZE := 200_000
FAST-DATA-SIZE := 5_000_000

MCLK-MULTIPLIER ::= 512

// See https://github.com/espressif/esp-idf/issues/15275.
ALLOWED-ERRORS ::= 30

extract-stereo-out arg/string -> int?:
  if arg.contains "outstereoleft": return i2s.Bus.SLOTS-STEREO-LEFT
  else if arg.contains "outstereoright": return i2s.Bus.SLOTS-STEREO-RIGHT
  else if arg.contains "outmonoboth": return i2s.Bus.SLOTS-MONO-BOTH
  else if arg.contains "outmonoleft": return i2s.Bus.SLOTS-MONO-LEFT
  else if arg.contains "outmonoright": return i2s.Bus.SLOTS-MONO-RIGHT
  else: return null

extract-stereo-in arg/string -> int?:
  if arg.contains "inmonoleft": return i2s.Bus.SLOTS-MONO-LEFT
  else if arg.contains "inmonoright": return i2s.Bus.SLOTS-MONO-RIGHT
  else: return null

extract-format arg/string -> int?:
  if arg.contains "philips": return i2s.Bus.FORMAT-PHILIPS
  else if arg.contains "msb": return i2s.Bus.FORMAT-MSB
  else if arg.contains "pcm": return i2s.Bus.FORMAT-PCM-SHORT
  else: return null

extract-data-size arg/string -> int?:
  if arg.contains "8": return 8
  if arg.contains "16": return 16
  if arg.contains "24": return 24
  else if arg.contains "32": return 32
  else: return null

extract-mclk arg/string -> bool?:
  return arg.contains "mclk"

extract-master arg/string -> bool:
  return not arg.contains "slave"

extract-is-writer arg/string -> bool:
  return arg.contains "writer"

extract-is-fast-test arg/string -> bool:
  return arg.contains "fast"

board1 args/List:
  data := gpio.Pin DATA1
  clk := gpio.Pin CLK1
  ws := gpio.Pin WS1
  mclk := gpio.Pin MCLK1

  test --board1 --data=data --clk=clk --ws=ws --mclk=mclk args

board2 args/List:
  data := gpio.Pin DATA2
  clk := gpio.Pin CLK2
  ws := gpio.Pin WS2
  mclk := gpio.Pin MCLK2

  test --no-board1 --data=data --clk=clk --ws=ws --mclk=mclk args

test args/List
    --board1/bool
    --data/gpio.Pin
    --clk/gpio.Pin
    --ws/gpio.Pin
    --mclk/gpio.Pin:
  arg := args[0]
  format := extract-format arg
  data-size := extract-data-size arg
  is-mclk-master := extract-mclk arg
  master := extract-master arg
  is-writer := extract-is-writer arg
  is-fast-test := extract-is-fast-test arg
  stereo-in := extract-stereo-in arg
  stereo-out := extract-stereo-out arg
  sample-rate := is-fast-test ? FAST-SAMPLE-RATE : SLOW-SAMPLE-RATE
  allowed-errors := ALLOWED-ERRORS
  use-mclk := is-mclk-master
  mclk-frequency/int? := null
  mclk-multiplier/int? := null

  if is-mclk-master and system.architecture == system.ARCHITECTURE-ESP32:
    // Not supported on this architecture.
    // The ESP32 has a master clk output, but no input. Furthermore, the
    // output must be on a specific pin.
    print ALL-TESTS-DONE
    return

  if board1:
    mclk-multiplier = MCLK-MULTIPLIER
  else:
    master = not master
    is-writer = not is-writer
    is-mclk-master = not is-mclk-master
    // The mclk has a multiplier of MCLK-MULTIPLIER which is based on the sample-rate.
    mclk-frequency = sample-rate * MCLK-MULTIPLIER

  // Writers never fail. It's the reader that has to confirm that the test succeeded.
  // The only exception is the fast test, where we look at the error count.
  run-test --background=(is-writer and not is-fast-test):
    generator/DataGenerator := is-fast-test
        ? FastGenerator data-size
        : VerifyingDataGenerator data-size
              --needs-synchronization
              --allowed-errors=allowed-errors
              --stereo-in=stereo-in
              --stereo-out=stereo-out

    channel/i2s.Bus := ?
    if is-writer:
      channel = i2s.Bus
          --master=master
          --mclk=use-mclk ? mclk : null
          --tx=data
          --sck=clk
          --ws=ws

      channel.configure
          --sample-rate=sample-rate
          --bits-per-sample=data-size
          --format=format
          --mclk-multiplier=use-mclk ? mclk-multiplier : null
          --mclk-external-frequency=use-mclk ? mclk-frequency : null
          --slots=stereo-out

      if is-fast-test:
        // Preload the data.
        while true:
          preloaded := generator.do: channel.preload it
          if preloaded == 0: break

      channel.start

      printed-done := false
      while true:
        expect-equals 0 channel.errors
        generator.do: channel.write it

        if is-fast-test:
          // We need to stop the test ourselves, since we are not background.
          if generator.written > FAST-DATA-SIZE:
            // Don't stop producing.
            if not printed-done:
              print_ ALL-TESTS-DONE
              printed-done = true
      expect-equals 0 channel.errors

    else:
      channel = i2s.Bus
          --master=master
          --mclk=use-mclk ? mclk : null
          --rx=data
          --sck=clk
          --ws=ws

      channel.configure
          --sample-rate=sample-rate
          --bits-per-sample=data-size
          --format=format
          --mclk-multiplier=use-mclk ? mclk-multiplier : null
          --mclk-external-frequency=use-mclk ? mclk-frequency : null
          --slots=stereo-in

      channel.start

      required-size := is-fast-test
          ? FAST-DATA-SIZE
          : SLOW-DATA-SIZE
      printed-done := false
      in-buffer := ByteArray 2048
      all-read := 0
      last-channel-errors := 0
      while true:
        chunk/ByteArray := ?
        if is-fast-test:
          chunk-size := channel.read in-buffer
          chunk = in-buffer[..chunk-size]
        else:
          chunk = channel.read
        current-errors := channel.errors
        if current-errors != last-channel-errors:
          print "Errors: $current-errors"
          last-channel-errors = current-errors
          generator.increment-error
        all-read += chunk.size
        generator.verify chunk
        if generator.verified > required-size:
          // Don't stop consuming.
          if not printed-done:
            print ALL-TESTS-DONE
            print "Consumed: $generator.verified  $all-read"
            printed-done = true
      expect-equals 0 channel.errors
