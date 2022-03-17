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


  write_bits count/int bits/int:

  // TODO Do we want a write bytes?

  read_bits count/int -> int:
    return 0

  // TODO Do we want a read bytes?

  reset -> bool:
    periods := [
      RESET_LOW_DURATION_STD,
      0
    ]
    signals := rmt.Signals.alternating --first_level=0 periods
    received_signals := rmt.transfer_and_receive --rx=rx_channel_ --tx=tx_channel_ signals 32

    print "signal count: $received_signals.size"
    received_signals.do: | period level |
      print "period: $period, level: $level"

    // TODO check the returned signals.

    return false


  static RESET_INIT_DURATION_STD    ::= 0
  static RESET_LOW_DURATION_STD     ::= 480
  static RESET_SAMPLE_DELAY_STD     ::= 70
  static RESET_SAMPLE_DURATION_STD  ::= 480


config_ow_pin_ pin rx tx:
  #primitive.one_wire.config_pin
