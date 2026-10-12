// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import i2s
import system
import ..shared.i2s-pattern
import .wiring show *

// Eight silent training frames, then a strict periodic payload on PAD22.
// Deliberately leave the producer asleep for 150 ms after master start.
main args:
  parts := args[0].split ","
  rate := int.parse parts[0]
  bits := int.parse parts[1]
  format := int.parse parts[2]
  master := parts[3] == "master"
  slots := int.parse parts[4]
  expect-equals "tx" parts[5]
  data := pattern bits --slots=slots --inverted
  bus := i2s.Bus --master=master --tx=EC618-I2S1-TX-PAD --sck=EC618-I2S1-SCK-PAD --ws=EC618-I2S1-WS-PAD
      --mclk=(master ? EC618-I2S1-MCLK-PAD : null)
  go/gpio.Pin? := null
  try:
    if master: go = gpio.Pin EC618-I2S-PEER-READY-PAD --input --pull-down
    bus.configure --sample-rate=rate --bits-per-sample=bits --format=format
        --buffer-duration-ms=(rate > 16_000 ? 200 : null)
        --slots-in=i2s.Bus.SLOTS-STEREO-BOTH
        --slots-out=slots
    channels := slots <= i2s.Bus.SLOTS-STEREO-RIGHT ? 2 : 1
    training := ByteArray (TRAINING-FRAMES * bits / 8 * channels)
    expect-equals training.size (bus.preload training)
    offset := 0
    while true:
      n := bus.preload data[offset..]
      if n == 0: break
      offset = (offset + n) % data.size
    if not master: bus.start
    print "I2S TX READY master=$master rate=$rate bits=$bits format=$format slots=$slots"
    started-us := 0
    max-write-us := 0
    max-gc-write-us := 0
    max-idle-us := 0
    first-loss-write := -1
    first-loss-us := -1
    first-loss-count := 0
    with-timeout --ms=20_000:
      if master:
        go.wait-for 1
        started-us = Time.monotonic-us
        bus.start
        sleep --ms=150
      else:
        started-us = Time.monotonic-us
      if offset != 0: bus.write data[offset..]
      last-end := Time.monotonic-us
      // The peer captures up to 768 * 504 physical stereo bytes. At eight
      // bits, 512 periods provide fewer frames than that capture requires.
      periods := bits == 8 ? 1024 : 512
      expect (periods * PERIOD * 2 * (bits / 8)) > 768 * 504
      periods.repeat: |index/int|
        before := Time.monotonic-us
        max-idle-us = max max-idle-us (before - last-end)
        gc-before := system.gc-count
        bus.write data
        after := Time.monotonic-us
        elapsed := after - before
        max-write-us = max max-write-us elapsed
        if system.gc-count != gc-before:
          max-gc-write-us = max max-gc-write-us elapsed
        losses := bus.errors --underrun
        if losses > 0 and first-loss-write < 0:
          first-loss-write = index
          first-loss-us = after - started-us
          first-loss-count = losses
        last-end = after
    underruns := bus.errors --underrun
    bus.stop
    print "I2S WRITE TIMING max_write_us=$max-write-us max_gc_write_us=$max-gc-write-us max_idle_us=$max-idle-us first_loss_write=$first-loss-write first_loss_us=$first-loss-us first_loss_count=$first-loss-count"
    print "I2S TX TRAINED training=$TRAINING-FRAMES producer_stall_ms=$(master ? 150 : 0) underruns=$underruns"
    expect-equals 0 underruns
    print "I2S TX PASS master=$master rate=$rate bits=$bits format=$format slots=$slots errors=0"
  finally:
    bus.close
    if go: go.close
