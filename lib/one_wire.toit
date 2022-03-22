// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import rmt

class OneWire:
  static RESET_INIT_DURATION_STD    ::= 0
  static RESET_LOW_DURATION_STD     ::= 480
  static RESET_SAMPLE_DELAY_STD     ::= 70
  static RESET_SAMPLE_DURATION_STD  ::= 480

  static IO_TIME_SLOT ::= 70
  static READ_INIT_TIME_STD ::= 6
  static READ_SAMPLE_TIME_STD ::= 9
  static WRITE_1_LOW_DELAY ::= READ_INIT_TIME_STD
  static WRITE_0_LOW_DELAY ::= 60

  static SIGNALS_PER_BIT ::= 2

  rx_channel_/rmt.Channel
  tx_channel_/rmt.Channel

  constructor --rx --tx:
    rx_channel_ = rx
    tx_channel_ = tx
    tx_channel_.config_tx --idle_level=1
    // TODO handle idle threshold
    rx_channel_.config_rx --filter_ticks_thresh=30 --idle_threshold=3000 --rx_buffer_size=1024

    config_ow_pin_ rx_channel_.pin.num rx_channel_.num tx_channel_.num


  /**
  Writes the given bytes and then reads the given $byte_count number of bytes.

  There is no interruption between the write and the read. Should be used when
    the read must happen immediately after the write.
  */
  write_then_read bytes/ByteArray byte_count/int -> ByteArray:
    // TODO: Check that we have allocated a sufficiently large RX buffer.
    signals := encode_write_then_read_signals_ bytes byte_count
    expected_bytes_count := (bytes.size + byte_count) * BITS_PER_BYTE * rmt.BYTES_PER_SIGNAL * SIGNALS_PER_BIT
    received_signals := rmt.transfer_and_receive --rx=rx_channel_ --tx=tx_channel_ signals expected_bytes_count
    return decode_signals_to_bytes_ received_signals --from=bytes.size byte_count

  static encode_write_then_read_signals_ bytes/ByteArray read_bytes_count/int -> rmt.Signals:
    signals := rmt.Signals (bytes.size + read_bytes_count) * rmt.BYTES_PER_SIGNAL * BITS_PER_BYTE
    i := 0
    bytes.do:
      encode_write_signals_ signals it --from=i
      i += 8 * 2
    encode_read_signals_ signals --from=i --bit_count=read_bytes_count * BITS_PER_BYTE
    return signals

  /**
  TODO write the rest of the Toit doc

  The given $from is the number of bytes to skip in the signals.
  */
  static decode_signals_to_bytes_ signals/rmt.Signals --from/int=0 byte_count/int -> ByteArray:
    // TODO check signal size.
    write_signal_count := from * rmt.BYTES_PER_SIGNAL * BITS_PER_BYTE
    result := ByteArray byte_count: 0
    byte_count.repeat:
      i := write_signal_count + it * 16
      result[it] = decode_read_signals_ signals --from=i
    return result

  static encode_read_signals_ signals/rmt.Signals --from/int=0 --bit_count/int:
    assert: 0 <= from
    assert: from + bit_count * 2 <= signals.size
    bit_count.repeat:
      signals.set_signal from + it * 2 READ_INIT_TIME_STD 0
      signals.set_signal from + it * 2 + 1 IO_TIME_SLOT - READ_INIT_TIME_STD 1

  write_bits bits/int count/int -> none:
    signals :=  rmt.Signals count * 2
    encode_write_signals_ signals bits --count=count
    rmt.transfer tx_channel_ signals

  static encode_write_signals_ signals/rmt.Signals bits/int --from/int=0 --count/int=8 -> none:
    write_signal_count := count * 2
    assert: 0 <= from < signals.size
    assert: from + write_signal_count < signals.size
    print "$(%x bits)"
    count.repeat:
      // Write the lowest bit.
      delay := 0
      if bits & 0x01 == 1:
        delay = WRITE_1_LOW_DELAY
      else:
        delay = WRITE_0_LOW_DELAY
      signals.set_signal from + it * 2 delay 0
      signals.set_signal from + it * 2 + 1 IO_TIME_SLOT - delay 1
      bits = bits >> 1

  // TODO Do we want a write bytes?

  read_bits count/int -> int:
    read_signals := rmt.Signals count * 2
    encode_read_signals_ read_signals --bit_count= count
    signals := rmt.transfer_and_receive --rx=rx_channel_ --tx=tx_channel_
        read_signals
        (count + 1) * 8
    print_ signals
    return decode_read_signals_ signals count

  static decode_read_signals_ signals/rmt.Signals --from/int=0 count/int=8 -> int:
    result := 0
    count.repeat:
      i := from + it * 2
      if (signals.signal_level i) != 0: throw "unexpected signal"

      if (signals.signal_level i + 1) != 1: throw "unexpected signal"

      result = result >> 1
      if (signals.signal_period i) < 17: result = result | 0x80
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
        4 * rmt.BYTES_PER_SIGNAL

    // TODO(Lau): Should we throw if the signals did not look like we expect?
    return received_signals.size >= 3 and
        // We observe the first low pulse that we sent.
        (received_signals.signal_level 0) == 0 and RESET_LOW_DURATION_STD - 2 <= (received_signals.signal_period 0) <= RESET_LOW_DURATION_STD + 10 and
        // We release the bus so it becomes high.
        (received_signals.signal_level 1) == 1 and (received_signals.signal_period 1) > 0 and
        // The receiver signals its presence.
        (received_signals.signal_level 2) == 0 and (received_signals.signal_period 2) > 0


config_ow_pin_ pin rx tx:
  #primitive.one_wire.config_pin
