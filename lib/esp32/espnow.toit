// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

STATION_ ::= 0 // Wi-Fi station mode
SOFTAP_  ::= 1 // Not support yet

BROADCAST_ADDRESS ::= Address #[0xff, 0xff, 0xff, 0xff, 0xff, 0xff]

/** 1 Mbps with long preamble. */
RATE_1M_L ::= 0x00
/** 2 Mbps with long preamble. */
RATE_2M_L ::= 0x01
/** 5.5 Mbps with long preamble. */
RATE_5M_L ::= 0x02
/** 11 Mbps with long preamble. */
RATE_11M_L ::= 0x03
/** 2 Mbps with short preamble. */
RATE_2M_S ::= 0x05
/** 5.5 Mbps with short preamble. */
RATE_5M_S ::= 0x06
/** 11 Mbps with short preamble. */
RATE_11M_S ::= 0x07
/** 48 Mbps. */
RATE_48M ::= 0x08
/** 24 Mbps. */
RATE_24M ::= 0x09
/** 12 Mbps. */
RATE_12M ::= 0x0A
/** 6 Mbps. */
RATE_6M ::= 0x0B
/** 54 Mbps. */
RATE_54M ::= 0x0C
/** 36 Mbps. */
RATE_36M ::= 0x0D
/** 18 Mbps. */
RATE_18M ::= 0x0E
/** 9 Mbps. */
RATE_9M ::= 0x0F
/** MCS0 with long GI, 6.5 Mbps for 20MHz, 13.5 Mbps for 40MHz. */
RATE_MCS0_LGI ::= 0x10
/** MCS1 with long GI, 13 Mbps for 20MHz, 27 Mbps for 40MHz. */
RATE_MCS1_LGI ::= 0x11
/** MCS2 with long GI, 19.5 Mbps for 20MHz, 40.5 Mbps for 40MHz. */
RATE_MCS2_LGI ::= 0x12
/** MCS3 with long GI, 26 Mbps for 20MHz, 54 Mbps for 40MHz. */
RATE_MCS3_LGI ::= 0x13
/** MCS4 with long GI, 39 Mbps for 20MHz, 81 Mbps for 40MHz. */
RATE_MCS4_LGI ::= 0x14
/** MCS5 with long GI, 52 Mbps for 20MHz, 108 Mbps for 40MHz. */
RATE_MCS5_LGI ::= 0x15
/** MCS6 with long GI, 58.5 Mbps for 20MHz, 121.5 Mbps for 40MHz. */
RATE_MCS6_LGI ::= 0x16
/** MCS7 with long GI, 65 Mbps for 20MHz, 135 Mbps for 40MHz. */
RATE_MCS7_LGI ::= 0x17
/** MCS0 with short GI, 7.2 Mbps for 20MHz, 15 Mbps for 40MHz. */
RATE_MCS0_SGI ::= 0x18
/** MCS1 with short GI, 14.4 Mbps for 20MHz, 30 Mbps for 40MHz. */
RATE_MCS1_SGI ::= 0x19
/** MCS2 with short GI, 21.7 Mbps for 20MHz, 45 Mbps for 40MHz. */
RATE_MCS2_SGI ::= 0x1A
/** MCS3 with short GI, 28.9 Mbps for 20MHz, 60 Mbps for 40MHz. */
RATE_MCS3_SGI ::= 0x1B
/** MCS4 with short GI, 43.3 Mbps for 20MHz, 90 Mbps for 40MHz. */
RATE_MCS4_SGI ::= 0x1C
/** MCS5 with short GI, 57.8 Mbps for 20MHz, 120 Mbps for 40MHz. */
RATE_MCS5_SGI ::= 0x1D
/** MCS6 with short GI, 65 Mbps for 20MHz, 135 Mbps for 40MHz. */
RATE_MCS6_SGI ::= 0x1E
/** MCS7 with short GI, 72.2 Mbps for 20MHz, 150 Mbps for 40MHz. */
RATE_MCS7_SGI ::= 0x1F
/** 250 Kbps. */
RATE_LORA_250K ::= 0x29
/** 500 Kbps. */
RATE_LORA_500K ::= 0x2A

class Address:
  mac/ByteArray

  constructor .mac:
    if mac.size != 6:
        throw "ESP-Now MAC address length must be 6 bytes"

  stringify -> string:
    return "$(%02x mac[0]):$(%02x mac[1]):$(%02x mac[2]):$(%02x mac[3]):$(%02x mac[4]):$(%02x mac[5])"

class Key:
  data/ByteArray

  constructor .data/ByteArray:
    if data.size != 16:
        throw "ESP-Now key length must be 16 bytes"

  constructor.from_string string_data/string:
    return Key string_data.to_byte_array

class Datagram:
  address/Address
  data/ByteArray

  constructor .address .data:

class Service:
  resource_ := ?

  /**
  Constructs a new ESP-Now service in station mode.

  The $rate parameter, if provided, must be a valid ESP-Now rate constant. See
    $RATE_1M_L for example. By default, the rate is set to 1Mbps.
  */
  constructor.station --key/Key? --rate/int?=null:
    key_data := key ? key.data : #[]
    if rate and rate < 0: throw "INVALID_ARGUMENT"
    if not rate: rate = -1
    resource_ = espnow_create_ resource_group_ STATION_ key_data rate

  close -> none:
    if not resource_: return
    critical_do:
      espnow_close_ resource_
      resource_ = null

  send data/ByteArray --address/Address --wait/bool=true -> none:
    espnow_send_ address.mac data wait

  receive -> Datagram?:
    array := espnow_receive_ (Array_ 2)
    if not array: return null
    address := Address array[0]
    return Datagram address array[1]

  add_peer address/Address --channel/int --key/Key?=null -> bool:
    if not 0 <= channel <= 14:
      throw "ESP-Now channel range must be 0-14"

    key_data := key ? key.data : #[]
    return espnow_add_peer_ address.mac channel key_data

resource_group_ ::= espnow_init_

espnow_init_:
  #primitive.espnow.init

espnow_create_ group mode pmk rate:
  #primitive.espnow.create

espnow_close_ resource:
  #primitive.espnow.close

espnow_send_ mac data wait:
  #primitive.espnow.send

espnow_receive_ output:
  #primitive.espnow.receive

espnow_add_peer_ mac channel key:
  #primitive.espnow.add_peer
