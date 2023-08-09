// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor
import monitor show ResourceState_

STATION_ ::= 0 // Wi-Fi station mode
SOFTAP_  ::= 1 // Not support yet

BROADCAST-ADDRESS ::= Address #[0xff, 0xff, 0xff, 0xff, 0xff, 0xff]

/** 1 Mbps with long preamble. */
RATE-1M-L ::= 0x00
/** 2 Mbps with long preamble. */
RATE-2M-L ::= 0x01
/** 5.5 Mbps with long preamble. */
RATE-5M-L ::= 0x02
/** 11 Mbps with long preamble. */
RATE-11M-L ::= 0x03
/** 2 Mbps with short preamble. */
RATE-2M-S ::= 0x05
/** 5.5 Mbps with short preamble. */
RATE-5M-S ::= 0x06
/** 11 Mbps with short preamble. */
RATE-11M-S ::= 0x07
/** 48 Mbps. */
RATE-48M ::= 0x08
/** 24 Mbps. */
RATE-24M ::= 0x09
/** 12 Mbps. */
RATE-12M ::= 0x0A
/** 6 Mbps. */
RATE-6M ::= 0x0B
/** 54 Mbps. */
RATE-54M ::= 0x0C
/** 36 Mbps. */
RATE-36M ::= 0x0D
/** 18 Mbps. */
RATE-18M ::= 0x0E
/** 9 Mbps. */
RATE-9M ::= 0x0F
/** MCS0 with long GI, 6.5 Mbps for 20MHz, 13.5 Mbps for 40MHz. */
RATE-MCS0-LGI ::= 0x10
/** MCS1 with long GI, 13 Mbps for 20MHz, 27 Mbps for 40MHz. */
RATE-MCS1-LGI ::= 0x11
/** MCS2 with long GI, 19.5 Mbps for 20MHz, 40.5 Mbps for 40MHz. */
RATE-MCS2-LGI ::= 0x12
/** MCS3 with long GI, 26 Mbps for 20MHz, 54 Mbps for 40MHz. */
RATE-MCS3-LGI ::= 0x13
/** MCS4 with long GI, 39 Mbps for 20MHz, 81 Mbps for 40MHz. */
RATE-MCS4-LGI ::= 0x14
/** MCS5 with long GI, 52 Mbps for 20MHz, 108 Mbps for 40MHz. */
RATE-MCS5-LGI ::= 0x15
/** MCS6 with long GI, 58.5 Mbps for 20MHz, 121.5 Mbps for 40MHz. */
RATE-MCS6-LGI ::= 0x16
/** MCS7 with long GI, 65 Mbps for 20MHz, 135 Mbps for 40MHz. */
RATE-MCS7-LGI ::= 0x17
/** MCS0 with short GI, 7.2 Mbps for 20MHz, 15 Mbps for 40MHz. */
RATE-MCS0-SGI ::= 0x18
/** MCS1 with short GI, 14.4 Mbps for 20MHz, 30 Mbps for 40MHz. */
RATE-MCS1-SGI ::= 0x19
/** MCS2 with short GI, 21.7 Mbps for 20MHz, 45 Mbps for 40MHz. */
RATE-MCS2-SGI ::= 0x1A
/** MCS3 with short GI, 28.9 Mbps for 20MHz, 60 Mbps for 40MHz. */
RATE-MCS3-SGI ::= 0x1B
/** MCS4 with short GI, 43.3 Mbps for 20MHz, 90 Mbps for 40MHz. */
RATE-MCS4-SGI ::= 0x1C
/** MCS5 with short GI, 57.8 Mbps for 20MHz, 120 Mbps for 40MHz. */
RATE-MCS5-SGI ::= 0x1D
/** MCS6 with short GI, 65 Mbps for 20MHz, 135 Mbps for 40MHz. */
RATE-MCS6-SGI ::= 0x1E
/** MCS7 with short GI, 72.2 Mbps for 20MHz, 150 Mbps for 40MHz. */
RATE-MCS7-SGI ::= 0x1F
/** 250 Kbps. */
RATE-LORA-250K ::= 0x29
/** 500 Kbps. */
RATE-LORA-500K ::= 0x2A

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

  constructor.from-string string-data/string:
    return Key string-data.to-byte-array

class Datagram:
  address/Address
  data/ByteArray

  constructor .address .data:

class Service:
  send-mutex_/monitor.Mutex ::= monitor.Mutex
  resource_ := ?
  state_ := ?

  /**
  Constructs a new ESP-Now service in station mode.

  The $rate parameter, if provided, must be a valid ESP-Now rate constant. See
    $RATE-1M-L for example. By default, the rate is set to 1Mbps.
  */
  constructor.station --key/Key? --rate/int?=null:
    key-data := key ? key.data : #[]
    if rate and rate < 0: throw "INVALID_ARGUMENT"
    if not rate: rate = -1
    resource_ = espnow-create_ resource-group_ STATION_ key-data rate
    state_ = ResourceState_ resource-group_ resource_

  close -> none:
    if not resource_: return
    critical-do:
      espnow-close_ resource_
      resource_ = null

  /**
  Deprecated. The $wait flag is ignored.
  */
  send data/ByteArray --address/Address --wait/bool -> none:
    send data --address=address

  /**
  Sends the given $data to the given $address.

  The $data must be at most 250 bytes long.
  Waits for the transmission to complete.
  */
  send data/ByteArray --address/Address -> none:
    send-mutex_.do:
      state_.clear-state SEND-DONE-STATE_
      espnow-send_ resource_ address.mac data
      state_.wait-for-state SEND-DONE-STATE_
      succeeded := espnow-send-succeeded_ resource_
      if not succeeded:
        throw "ESP-Now send failed"

  /**
  Receives a datagram.

  Blocks until a datagram is received.
  */
  receive -> Datagram?:
    while true:
      // Always try to read directly. If there is no data available we
      // will wait for the state to change.
      state_.clear-state DATA-AVAILABLE-STATE_
      result := espnow-receive_ resource_
      if not result:
        state_.wait-for-state DATA-AVAILABLE-STATE_
        continue

      address := Address result[0]
      return Datagram address result[1]

  add-peer address/Address --channel/int --key/Key?=null -> bool:
    if not 0 <= channel <= 14:
      throw "ESP-Now channel range must be 0-14"

    key-data := key ? key.data : #[]
    return espnow-add-peer_ resource_ address.mac channel key-data

resource-group_ ::= espnow-init_

DATA-AVAILABLE-STATE_ ::= 1 << 0
SEND-DONE-STATE_ ::= 1 << 1

espnow-init_:
  #primitive.espnow.init

espnow-create_ group mode pmk rate:
  #primitive.espnow.create

espnow-close_ resource:
  #primitive.espnow.close

espnow-send_ resource mac data:
  #primitive.espnow.send

espnow-send-succeeded_ resource:
  #primitive.espnow.send-succeeded

espnow-receive_ resource:
  #primitive.espnow.receive

espnow-add-peer_ resource mac channel key:
  #primitive.espnow.add-peer
