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

  constructor.from_bytes bytes/ByteArray index/int:
    period = (bytes[index] << 8 | bytes[index + 1]) >> 1
    value = bytes[index + 1] & 0x01

  first_byte -> int:
    return period >> 7

  second_byte -> int:
    return ((period << 1) & 0xFF) | value

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
    if rx: rmt_config_ rx.num rx_ch false 500
    if tx: rmt_config_ tx.num tx_ch true 0

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

rmt_config_ pin_num/int channel_num/int is_tx/bool mem_block_num/int:
  #primitive.rmt.config

rmt_transfer_ tx_ch/int items_bytes/*/Blob*/:
  #primitive.rmt.transfer

rmt_transfer_and_read_ tx_ch/int rx_ch/int items_bytes max_output_len/int:
  #primitive.rmt.transfer_and_read
