// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import ble.experimental.service.advertising-provider as service
import ble.experimental.transport
import monitor
import .advertising-update-exit as fixture

main:
  provider := Provider
  provider.install
  try:
    provider.uninstall --wait
    if provider.opens != 2 or provider.closes != 2 or provider.enables != 2 or provider.disables != 0 or
        provider.data-updates != 8 or provider.response-updates != 8:
      throw "ADVERTISING_UPDATE_EXIT_CONTROLLER_COUNTS"
    print "ADVERTISING_UPDATE_EXIT_PROVIDER COMPLETE opens=2 closes=2 enables=2 disables=0 data=8 response=8"
  finally:
    provider.uninstall

class Provider extends service.Provider:
  held/List ::= [monitor.Latch, monitor.Latch]
  first-closed/monitor.Latch ::= monitor.Latch
  opens/int := 0
  closes/int := 0
  enables/int := 0
  disables/int := 0
  data-updates/int := 0
  response-updates/int := 0
  constructor: super

  open-transport -> transport.Transport:
    mode := opens++
    if mode > 1: throw "ADVERTISING_UPDATE_EXIT_EXTRA_OPEN"
    return Radio this mode

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == fixture.WAIT-PREVIOUS:
      first-closed.get
      sleep --ms=3_000
      return null
    if index == fixture.WAIT-HELD:
      mode/int := arguments
      held[mode].get
      return null
    return super index arguments --gid=gid --client=client

class Radio implements transport.Transport:
  owner_/Provider
  mode_/int
  radio_/esp32.Esp32Transport ::= esp32.Esp32Transport
  release_/monitor.Latch ::= monitor.Latch
  responses_/int := 0
  constructor .owner_ .mode_:

  receive -> ByteArray:
    packet := radio_.receive
    if packet.size == 7 and packet[0] == 4 and packet[1] == 14 and packet[4] == 9 and packet[5] == 32:
      responses_++
      if responses_ == 4:
        if packet[6] != 0: throw "ADVERTISING_UPDATE_EXIT_COMMAND_REJECTED"
        print "ADVERTISING_UPDATE HELD mode=$mode_ opcode=8201 status=0"
        owner_.held[mode_].set true
        release_.get
    return packet

  close -> none:
    owner_.closes++
    release_.set true
    radio_.close
    if mode_ == 0: owner_.first-closed.set true

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
