// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import rmt

/**
Support for 1-wire protocol.

The 1-wire protocol is implemented with ESP32's hardware supported RMT module.
*/

/**
The 1-wire protocol.

Use $read_bits and $write_bits to read or write bytes to the receiver.

Use $write_then_read to write bytes to the receiver and then immediately start reading.

Use $reset to reset the receiver.
*/
class OneWire:
  static RESET_LOW_DURATION_STD ::= 480

  static IO_TIME_SLOT ::= 70
  static READ_INIT_TIME_STD ::= 6
  static WRITE_1_LOW_DELAY ::= 6
  static WRITE_0_LOW_DELAY ::= 60

  static SIGNALS_PER_BIT ::= 2
  static SIGNALS_PER_BYTE ::= BITS_PER_BYTE * SIGNALS_PER_BIT
  static INVALID_SIGNAL ::= "INVALID_SIGNAL"

  rx_channel_/rmt.Channel
  tx_channel_/rmt.Channel

  /**
  Constructs a 1-Wire protocol using the given $rx and $tx channel.

  Configures the channels and the underlying pin for 1-wire.
  */
  constructor --rx --tx --rx_buffer_size=1024:
    rx_channel_ = rx
    tx_channel_ = tx
    tx_channel_.config_tx --idle_level=1
    // TODO change idle threshold dynamically.
    rx_channel_.config_rx --filter_ticks_thresh=30 --idle_threshold=500 --rx_buffer_size=rx_buffer_size

    ow_config_pin_ rx_channel_.pin.num rx_channel_.num tx_channel_.num

  /**
  Writes the given bytes and then reads the given $byte_count number of bytes.

  There is no interruption between the write and the read. Should be used when
    the read must happen immediately after the write.
  */
  write_then_read bytes/ByteArray byte_count/int -> ByteArray:
    // TODO: Check that we have allocated a sufficiently large RX buffer.
    signals := encode_write_then_read_signals_ bytes byte_count
    expected_bytes_count := (bytes.size + byte_count) * SIGNALS_PER_BYTE * rmt.BYTES_PER_SIGNAL
    received_signals := rmt.transfer_and_receive --rx=rx_channel_ --tx=tx_channel_ signals expected_bytes_count
    return decode_signals_to_bytes_ received_signals --from=bytes.size byte_count

  static encode_write_then_read_signals_ bytes/ByteArray read_bytes_count/int -> rmt.Signals:
    signals := rmt.Signals (bytes.size + read_bytes_count) * SIGNALS_PER_BYTE
    i := 0
    bytes.do:
      encode_write_signals_ signals it --from=i
      i += SIGNALS_PER_BYTE
    encode_read_signals_ signals --from=i --bit_count=read_bytes_count * BITS_PER_BYTE
    return signals

  /**
  Decodes the given $signals to bytes.

  Decoding starts from the given $from byte and decodes $byte_count bytes.
  */
  static decode_signals_to_bytes_ signals/rmt.Signals --from/int=0 byte_count/int -> ByteArray:
    assert: 0 <= from
    assert: 0 <= byte_count

    if from + byte_count * SIGNALS_PER_BYTE > signals.size: throw INVALID_SIGNAL

    write_signal_count := from * SIGNALS_PER_BYTE
    result := ByteArray byte_count: 0
    byte_count.repeat:
      result[it] = decode_signals_to_bits_ signals --from=write_signal_count + it * SIGNALS_PER_BYTE
    return result

  static encode_read_signals_ signals/rmt.Signals --from/int=0 --bit_count/int:
    assert: 0 <= from
    assert: from + bit_count * SIGNALS_PER_BIT <= signals.size
    bit_count.repeat:
      i := from + it * SIGNALS_PER_BIT
      signals.set_signal i READ_INIT_TIME_STD 0
      signals.set_signal i + 1 IO_TIME_SLOT - READ_INIT_TIME_STD 1

  /**
  Writes $count bits from $value to the receiver.
  */
  write_bits value/int count/int -> none:
    signals :=  rmt.Signals count * SIGNALS_PER_BIT
    encode_write_signals_ signals value --count=count
    rmt.transfer tx_channel_ signals

  static encode_write_signals_ signals/rmt.Signals bits/int --from/int=0 --count/int=8 -> none:
    write_signal_count := count * SIGNALS_PER_BIT
    assert: 0 <= from < signals.size
    assert: from + write_signal_count < signals.size
    count.repeat:
      // Write the lowest bit.
      delay := 0
      if bits & 0x01 == 1:
        delay = WRITE_1_LOW_DELAY
      else:
        delay = WRITE_0_LOW_DELAY
      i := from + it * SIGNALS_PER_BIT
      signals.set_signal i delay 0
      signals.set_signal i + 1 IO_TIME_SLOT - delay 1
      bits = bits >> 1

  // TODO Do we want a write bytes?

  /** Reads $count bits from the receiver. */
  read_bits count/int -> int:
    read_signals := rmt.Signals count * SIGNALS_PER_BIT
    encode_read_signals_ read_signals --bit_count=count
    signals := rmt.transfer_and_receive --rx=rx_channel_ --tx=tx_channel_ read_signals
        (count + 1) * SIGNALS_PER_BIT
    return decode_signals_to_bits_ signals --bit_count=count

  static decode_signals_to_bits_ signals/rmt.Signals --from/int=0 --bit_count/int=8 -> int:
    assert: 0 <= from
    assert: 0 <= bit_count
    if from + bit_count * SIGNALS_PER_BIT > signals.size: throw INVALID_SIGNAL

    result := 0
    bit_count.repeat:
      i := from + it * 2
      if (signals.signal_level i) != 0: throw "unexpected signal"

      if (signals.signal_level i + 1) != 1: throw "unexpected signal"

      result = result >> 1
      if (signals.signal_period i) < 17: result = result | 0x80
    result = result >> (8 - bit_count)

    return result

  /**
  Sends a reset to the receiver and reads whether the receiver is present.
  */
  reset -> bool:
    periods := [
      RESET_LOW_DURATION_STD,
      480
    ]
    received_signals := rmt.transfer_and_receive --rx=rx_channel_ --tx=tx_channel_
        rmt.Signals.alternating --first_level=0 periods
        4 * rmt.BYTES_PER_SIGNAL

    return received_signals.size >= 3 and
        // We observe the first low pulse that we sent.
        (received_signals.signal_level 0) == 0 and RESET_LOW_DURATION_STD - 2 <= (received_signals.signal_period 0) <= RESET_LOW_DURATION_STD + 10 and
        // We release the bus so it becomes high.
        (received_signals.signal_level 1) == 1 and (received_signals.signal_period 1) > 0 and
        // The receiver signals its presence.
        (received_signals.signal_level 2) == 0 and (received_signals.signal_period 2) > 0


ow_config_pin_ pin rx tx:
  #primitive.one_wire.config_pin
