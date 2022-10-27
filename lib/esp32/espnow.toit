// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

STATION ::= 0 // Wi-Fi station mode
SOFTAP  ::= 1 // Not support yet

check_mac_ address/ByteArray:
  if address.size != 6:
      throw "ESP-Now MAC address length must be 6 bytes"

check_key_ key/ByteArray:
  if key.size != 16:
      throw "ESP-Now key length must be 16 bytes"

check_channel_ channel/int:
  if not 0 <= channel <= 14:
      throw "ESP-Now channel range must be 0-14"

class Address:
  mac/ByteArray

  constructor .mac:
    check_mac_ mac

  stringify -> string:
    return "$(%02x mac[0]):$(%02x mac[1]):$(%02x mac[2]):$(%02x mac[3]):$(%02x mac[4]):$(%02x mac[5])"

class Key:
  data/ByteArray

  constructor .data/ByteArray:
    check_key_ data
  
  constructor.from_string string_data/string:
    return Key string_data.to_byte_array

class Datagram:
  address/Address
  data/ByteArray

  constructor .address .data:

class Service:
  _group ::= ?

  constructor --mode/int=STATION:
    _group = espnow_init_ mode #[]
  
  constructor.with_key --mode/int=STATION --key/Key:
    _group = espnow_init_ mode key.data

  send data/ByteArray --address/Address --wait/bool=true -> int:
    return espnow_send_ address.mac data wait

  receive -> Datagram?:
    array := espnow_receive_ (Array_ 2)
    if not array: return null
    address := Address array[0]
    return Datagram address array[1]

  add_peer address/Address --channel/int --key/Key?=null -> bool:
    key_data := #[]
    if key: key_data = key.data
    return espnow_add_peer_ address.mac channel key_data

espnow_init_ mode pmk:
  #primitive.espnow.init

espnow_send_ mac data wait:
  #primitive.espnow.send

espnow_receive_ output:
  #primitive.espnow.receive

espnow_add_peer_ mac channel key:
  #primitive.espnow.add_peer

BROADCAST_ADDRESS ::= Address #[0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
