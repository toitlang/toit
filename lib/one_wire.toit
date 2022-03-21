// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import rmt

class OneWire:

  rx_channel_/rmt.Channel
  tx_channel_/rmt.Channel

  constructor --rx --tx:
    rx_channel_ = rx
    tx_channel_ = tx
    tx_channel_.config_tx --idle_level=1
    rx_channel_.config_rx --filter_ticks_thresh=30 --idle_threshold=3000

    config_ow_pin_ rx_channel_.pin.num rx_channel_.num tx_channel_.num


  write_bits bits/int count/int -> none:
    write_signals := encode_write_signals_ bits count
    print_ write_signals
    rmt.transfer tx_channel_ write_signals

  encode_write_signals_ bits/int count/int -> rmt.Signals:
    previous_delay := 0
    return rmt.Signals.alternating count * 2 --first_level=0: | _ level |
        period := 0
        if level == 0:
          // Write the lowest bit.
          if bits & 0x01 == 1:
            previous_delay = period = WRITE_1_LOW_DELAY
          else:
            previous_delay = period = WRITE_0_LOW_DELAY
        else:
          period = IO_TIME_SLOT - previous_delay
          bits = bits >> 1
        period

  // TODO Do we want a write bytes?

  read_bits count/int -> int:
    read_signals := encode_write_signals_ count
    signals := rmt.transfer_and_receive --rx=rx_channel_ --tx=tx_channel_
        read_signals
        (count + 1) * 8
    print_ signals
    return decode_read_signals_ signals count

  static encode_write_signals_ count -> rmt.Signals:
    return rmt.Signals.alternating count * 2 --first_level=0: | _ level |
        level == 0 ? READ_INIT_TIME_STD : IO_TIME_SLOT - READ_INIT_TIME_STD

  static decode_read_signals_ signals/rmt.Signals count/int -> int:
    if signals.size < count * 2: throw "insufficiesnt signals received"
    result := 0
    count.repeat:
      // if (signals.signal_level it) != 0: throw "unexpected signal"

      // if (signals.signal_level it  + 1) != 1: throw "unexpected signal"

      result = result >> 1
      if (signals.signal_period it + 1) > 9: result | 0x80
    result = result >> (8 - count)

    return result

  // TODO Do we want a read bytes?
  print_ signals:
    print "signal count: $signals.size"
    signals.do: | period level |
      print "period: $period, level: $level"

  reset -> bool:
    periods := [
      RESET_LOW_DURATION_STD,
      480
    ]
    received_signals := rmt.transfer_and_receive --rx=rx_channel_ --tx=tx_channel_
        rmt.Signals.alternating --first_level=0 periods
        32

    // TODO(Lau): Should we throw if the signals did not look like we expect?
    return received_signals.size >= 3 and
        // We observe the first low pulse that we sent.
        (received_signals.signal_level 0) == 0 and RESET_LOW_DURATION_STD - 2 <= (received_signals.signal_period 0) <= RESET_LOW_DURATION_STD + 10 and
        // We release the bus so it becomes high.
        (received_signals.signal_level 1) == 1 and (received_signals.signal_period 1) > 0 and
        // The receiver signals its presence.
        (received_signals.signal_level 2) == 0 and (received_signals.signal_period 2) > 0

  static RESET_INIT_DURATION_STD    ::= 0
  static RESET_LOW_DURATION_STD     ::= 480
  static RESET_SAMPLE_DELAY_STD     ::= 70
  static RESET_SAMPLE_DURATION_STD  ::= 480

  static IO_TIME_SLOT ::= 70
  static READ_INIT_TIME_STD ::= 6
  static READ_SAMPLE_TIME_STD ::= 9
  static WRITE_1_LOW_DELAY ::= READ_INIT_TIME_STD
  static WRITE_0_LOW_DELAY ::= 60

config_ow_pin_ pin rx tx:
  #primitive.one_wire.config_pin
