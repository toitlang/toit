// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import ble.experimental.transport
import ble.experimental.service.gatt-provider as service

main:
  provider := Provider
  provider.install
  try:
    provider.uninstall --wait
    if provider.opens != 1 or provider.closes != 1 or provider.enables != 1 or provider.disables != 1 or
        provider.data-updates != 4 or provider.response-updates != 4:
      throw "CONNECTABLE_UPDATE_CONTROLLER_COUNTS"
    print "CONNECTABLE_UPDATE_PROVIDER COMPLETE opens=1 closes=1 enables=1 disables=1 data=4 response=4"
  finally:
    provider.uninstall

class Provider extends service.Provider:
  opens/int := 0
  closes/int := 0
  enables/int := 0
  disables/int := 0
  data-updates/int := 0
  response-updates/int := 0
  constructor: super
  receive-acl-packets -> int: return 4

  open-transport -> transport.Transport:
    opens++
    return Radio this

class Radio implements transport.Transport:
  owner_/Provider
  radio_/esp32.Esp32Transport ::= esp32.Esp32Transport
  closed_/bool := false
  constructor .owner_:
  receive -> ByteArray: return radio_.receive
  close -> none:
    if closed_: return
    closed_ = true
    owner_.closes++
    radio_.close
  send packet/ByteArray -> none:
    send-if packet: true

  send-if packet/ByteArray [allowed] -> bool:
    if not (radio_.send-if packet allowed): return false
    if packet.size >= 5 and packet[0] == 1 and packet[2] == 0x20:
      if packet[1] == 8: owner_.data-updates++
      if packet[1] == 9: owner_.response-updates++
      if packet[1] == 10:
        if packet[4] == 1: owner_.enables++
        else: owner_.disables++
    return true
