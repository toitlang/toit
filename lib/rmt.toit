// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio

class Item:
  value/int
  period/int

  constructor value period:
    this.period = period & 0x7FFF
    this.value = value & 0b1

  constructor.from_bytes index/int bytes/ByteArray:
    period = (bytes[index] << 8 | bytes[index + 1]) >> 1
    value = bytes[index + 1] & 0x01

  first_byte -> int:
    return period >> 7

  second_byte -> int:
    return ((period << 1) & 0xFF) | value

  operator == other/any:
    if other is not Item: return false

    return value == other.value and period == other.period

class Controller:
  rx_ch/int?
  rx/gpio.Pin?
  tx_ch/int?
  tx/gpio.Pin?

  rmt_rx_ := null
  rmt_tx_ := null

  constructor --.rx --.tx --.rx_ch --.tx_ch:
    if (not rx) and (not tx): throw "INVALID_ARGUMENT"
    if (rx and not rx_ch) or (not rx and rx_ch): throw "INVALID_ARGUMENT"
    if (tx and not tx_ch) or (not tx and tx_ch): throw "INVALID_ARGUMENT"
    if rx: rmt_rx_ = rmt_use_ resource_group_ rx_ch
    if tx: rmt_tx_ = rmt_use_ resource_group_ tx_ch
    config_

  config_:
    if rx: config_rx_ --pin_num=rx.num --channel_num=rx_ch --mem_block_num=1
    if tx: config_tx_ --pin_num=tx.num --channel_num=tx_ch

  config_rx_
      --pin_num/int
      --channel_num/int
      --mem_block_num/int=1
      --clk_div/int=80
      --flags/int=0
      --idle_threshold/int=12000
      --filter_en/bool=true
      --filter_ticks_thresh/int=100:
    rmt_config_rx_ rx.num rx_ch mem_block_num clk_div flags idle_threshold filter_en filter_ticks_thresh

  config_rx_
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

  transfer_and_read items max_items_size:
    max_output_len := 4096
    result := rmt_transfer_and_read_ tx_ch rx_ch
      items_to_bytes_ items
      max_output_len

    return bytes_to_items_ items

  bytes_to_items_ bytes/ByteArray -> List:
    items_size := bytes.size / 2
    result := List items_size
    items_size.repeat:
      result.add
        Item.from_bytes it * 2 bytes
    return result

  items_to_bytes_ items/List/*<Item>*/ -> ByteArray:
    should_pad := items.size % 2 == 0
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

rmt_config_rx_ pin_num/int channel_num/int mem_block_num/int clk_div/int flags/int idle_threshold/int filter_en/bool filter_ticks_thresh/int:
  #primitive.rmt.config_rx

rmt_config_tx_ pin_num/int channel_num/int mem_block_num/int clk_div/int flags/int
       carrier_en/bool carrier_freq_hz/int carrier_level/int carrier_duty_percent/int
       loop_en/bool idle_output_en/bool idle_level/int:
  #primitive.rmt.config_tx

rmt_transfer_ tx_ch/int items_bytes/*/Blob*/:
  #primitive.rmt.transfer

rmt_transfer_and_read_ tx_ch/int rx_ch/int items_bytes max_output_len/int:
  #primitive.rmt.transfer_and_read
