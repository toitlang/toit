// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

STATION ::= 0 // Wi-Fi station mode
SOFTAP  ::= 1 // Not support yet

BROADCAST_MAC ::= #[0xff, 0xff, 0xff, 0xff, 0xff, 0xff]

check_mac_ address/ByteArray:
  if address.size != 6:
      throw "ESP-Now MAC address length must be 6 bytes"

check_key_ key/ByteArray:
  if key.size != 16:
      throw "ESP-Now key length must be 16 bytes"

check_channel_ channel/int:
  if channel > 14 or channel < 0:
      throw "ESP-Now channel range must be 0~14"

class Address:
  address/ByteArray

  constructor .address:
    check_mac_ address

  stringify -> string:
    return "$(%02x address[0]):$(%02x address[1]):$(%02x address[2]):$(%02x address[3]):$(%02x address[4]):$(%02x address[5])"

class Datagram:
  address/Address
  data/ByteArray

  constructor .address .data:

class Service:
  _group ::= ?

  constructor --mode/int=STATION --pmk/ByteArray?=null:
    if not pmk:
      pmk = #[]
    else:
      check_key_ pmk
    _group = espnow_init_ mode pmk

  send data/ByteArray --address/ByteArray --wait/bool=true -> int:
    check_mac_ address
    return espnow_send_ address data wait

  receive -> Datagram?:
    array := espnow_receive_ (Array_ 2)
    if not array:
      return null
    return Datagram (Address array[0]) array[1]

  add_peer address/ByteArray --channel/int --lmk/ByteArray?=null --encrypted/bool=(lmk != null) -> bool:
    check_mac_ address
    if not lmk:
      lmk = #[]
    else:
      check_key_ lmk
    return espnow_add_peer_ address channel encrypted lmk

espnow_init_ mode pmk:
  #primitive.espnow.init

espnow_send_ addr data wait:
  #primitive.espnow.send

espnow_receive_ output:
  #primitive.espnow.receive

espnow_add_peer_ addr channel encrypted key:
  #primitive.espnow.add_peer
