// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio

/**
Each RMT item consists of a value/level and a period.

# Advanced
When an RMT value is written, then the given value is sustained for the given
  period. The period is specified in number of ticks, so the actual time the
  value is sustained is determined by the RMT controller configuration.

At the lower level, an item consits of 16 bits: 15 bits for the period and 1
  bit for the value/level.
*/
class Item:
  value/int
  period/int

  constructor period value:
    this.period = period & 0x7FFF
    this.value = value & 0b1

  constructor.from_bytes index/int bytes/ByteArray:
    period = bytes[index] | ((bytes[index + 1] & 0x7F) << 8)
    value = bytes[index + 1] >> 7

  first_byte -> int:
    return period & 0xFF

  second_byte -> int:
    return (period >> 8 ) | (value << 7)

  operator == other/any:
    if other is not Item: return false

    return value == other.value and period == other.period

  stringify -> string:
    return "($period, $value)"

class Controller:
  rx_ch/int?
  rx/gpio.Pin?
  tx_ch/int?
  tx/gpio.Pin?

  rmt_rx_/ByteArray? := null
  rmt_tx_/ByteArray? := null

  constructor --.rx --.tx --.rx_ch --.tx_ch:
    if (not rx) and (not tx): throw "INVALID_ARGUMENT"
    if (rx and not rx_ch) or (not rx and rx_ch): throw "INVALID_ARGUMENT"
    if (tx and not tx_ch) or (not tx and tx_ch): throw "INVALID_ARGUMENT"
    if rx: rmt_rx_ = rmt_use_ resource_group_ rx_ch
    if tx: rmt_tx_ = rmt_use_ resource_group_ tx_ch


  config_rx
      --pin_num/int
      --channel_num/int
      --mem_block_num/int=1
      --clk_div/int=80
      --flags/int=0
      --idle_threshold/int=12000
      --filter_en/bool=true
      --filter_ticks_thresh/int=100:
    rmt_config_rx_ rx.num rx_ch mem_block_num clk_div flags idle_threshold filter_en filter_ticks_thresh

  config_tx
      --pin_num/int
      --channel_num/int
      --mem_block_num/int=1
      --clk_div/int=80
      --flags/int=0
      --carrier_en/bool=false
      --carrier_freq_hz/int=38000
      --carrier_level/int=1
      --carrier_duty_percent/int=33
      --loop_en/bool=false
      --idle_output_en/bool=true
      --idle_level/int=0:
    rmt_config_tx_ tx.num tx_ch mem_block_num clk_div flags carrier_en carrier_freq_hz carrier_level carrier_duty_percent loop_en idle_output_en idle_level


  transfer items/List/*<Item>*/:
    if not rmt_tx_: throw "not configured for transfer"

    rmt_transfer_ tx_ch
      items_to_bytes_ items

  transfer_and_read items max_items_size -> List:
    max_output_len := 4096
    bytes := items_to_bytes_ items
    result := rmt_transfer_and_read_ tx_ch rx_ch
      bytes
      max_output_len
    return bytes_to_items_ result

  bytes_to_items_ bytes/ByteArray -> List:
    items_size := bytes.size / 2
    result := List items_size
    items_size.repeat:
      result[it] = Item.from_bytes it * 2 bytes
    return result

  items_to_bytes_ items/List/*<Item>*/ -> ByteArray:
    should_pad := items.size % 2 == 1
    // Ensure there is an even number of items.
    bytes_size := should_pad ? items.size * 2 + 2 : items.size * 2
    bytes := ByteArray bytes_size
    idx := 0

    items.do: | item/Item |
      bytes[idx] = item.first_byte
      bytes[idx + 1] = item.second_byte
      idx += 2

    if should_pad:
      bytes[idx] = 0
      bytes[idx + 1] = 0

    return bytes

  close:
    if rmt_rx_:
      rmt_unuse_ resource_group_ rmt_rx_
      rmt_rx_ = null
    if rmt_tx_:
      rmt_unuse_ resource_group_ rmt_tx_
      rmt_tx_ = null


resource_group_ ::= rmt_init_

rmt_init_:
  #primitive.rmt.init

rmt_use_ resource_group channel_num:
  #primitive.rmt.use

rmt_unuse_ resource_group resource:
  #primitive.rmt.unuse

rmt_config_rx_ pin_num/int channel_num/int mem_block_num/int clk_div/int flags/int
    idle_threshold/int filter_en/bool filter_ticks_thresh/int:
  #primitive.rmt.config_rx

rmt_config_tx_ pin_num/int channel_num/int mem_block_num/int clk_div/int flags/int
    carrier_en/bool carrier_freq_hz/int carrier_level/int carrier_duty_percent/int
    loop_en/bool idle_output_en/bool idle_level/int:
  #primitive.rmt.config_tx

rmt_transfer_ tx_ch/int items_bytes/*/Blob*/:
  #primitive.rmt.transfer

rmt_transfer_and_read_ tx_ch/int rx_ch/int items_bytes/*/Blob*/ max_output_len/int:
  #primitive.rmt.transfer_and_read
