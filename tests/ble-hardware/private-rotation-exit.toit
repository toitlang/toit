// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import ble.experimental.privacy
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.private-advertising-provider as advertising
import ble.experimental.service.provider as rpc
import monitor
import system

WAIT-HELD ::= 1000

main:
  with-timeout --ms=60_000:
    provider := Provider
    provider.install
    try:
      4.repeat: | stage/int |
        spawn:: application stage
        while provider.sessions.size <= stage: sleep --ms=1
        session/rpc.Session := provider.sessions[stage]
        while not session.is-released or not provider.closed.contains stage: sleep --ms=1
        collect
        provider.check stage
        print "PRIVATE_ROTATION_EXIT STOPPED stage=$stage released=true"
        sleep --ms=1_000
      // Check old transports again after subsequent owners used the controller.
      4.repeat: provider.check it
      print "PRIVATE_ROTATION_EXIT COMPLETE interrupted=3 recovered=1 opens=4 closes=4"
    finally:
      provider.uninstall

application stage/int:
  client := Client
  client.open --timeout=(Duration --s=10)
  try:
    data := #[2, 1, 6, 5, 0x16, 0xf0, 0xff, 0x72, stage]
    advertiser := client.start-advertising data
    data.fill 0
    collect
    print "PRIVATE_ROTATION_EXIT ACTIVE stage=$stage"
    if stage < 3:
      client.wait-held stage
      collect
      // Die before the ordinary three-second command deadline, bypassing
      // scoped cleanup in this process. The provider owns another heap.
      sleep --ms=500
      print "PRIVATE_ROTATION_EXIT EXIT stage=$stage pending=true"
      exit 0
    sleep --ms=2_000
    advertiser.stop
    client.close
    print "PRIVATE_ROTATION_EXIT RECOVERED stage=3 stopped=true"
  finally:
    if stage < 3: print "PRIVATE_ROTATION_EXIT UNEXPECTED_FINALLY stage=$stage"
    client.close

collect:
  before := system.process-stats
  after := system.process-stats --gc
  if after[system.STATS-INDEX-FULL-GC-COUNT] <= before[system.STATS-INDEX-FULL-GC-COUNT]:
    throw "PRIVATE_ROTATION_EXIT_GC_MISSING"

class Client extends clients.Client:
  constructor: super
  wait-held stage/int -> none: invoke_ WAIT-HELD stage

class Provider extends advertising.Provider:
  radios/List ::= []
  sessions/List ::= []
  closed/Set ::= {}
  pending-at-close/Set ::= {}
  addresses/List ::= []
  constructor: super (ByteArray 16: it + 1) --rotation-interval=(Duration --s=5)

  open-transport -> transport.Transport:
    if radios.size >= 4: throw "PRIVATE_ROTATION_EXIT_EXTRA_OPEN"
    radio := Radio this radios.size
    radios.add radio
    return radio

  create-advertising client/int arguments/List -> rpc.Session:
    session := super client arguments
    sessions.add session
    return session

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == WAIT-HELD:
      stage/int := arguments
      if not 0 <= stage < 3 or stage >= radios.size: throw "INVALID_ARGUMENT"
      if sessions[stage].owner-client != client: throw "INVALID_ARGUMENT"
      radios[stage].held.get
      return null
    return super index arguments --gid=gid --client=client

  on-closed client/int -> none:
    sessions.size.repeat: | stage/int |
      if sessions[stage].owner-client != client: continue.repeat
      radio/Radio := radios[stage]
      if radio.holding and Time.monotonic-us - radio.held-at < 2_500_000:
        pending-at-close.add stage
      closed.add stage
    super client

  check stage/int:
    radio/Radio := radios[stage]
    if not sessions[stage].is-released or radio.holding: throw "PRIVATE_ROTATION_EXIT_NOT_RELEASED"
    if stage < 3 and not pending-at-close.contains stage: throw "PRIVATE_ROTATION_EXIT_NOT_PENDING_AT_DEATH"
    enables := stage == 2 ? 2 : 1
    address-count := stage == 1 or stage == 2 ? 2 : 1
    if radio.closes != 1 or radio.enables != enables or radio.disables != 1 or
        radio.address-count != address-count or radio.data-count != 1 or radio.response-count != 1 or
        radio.holds != (stage < 3 ? 1 : 0):
      throw "PRIVATE_ROTATION_EXIT_COMMAND_COUNTS"
    print "PRIVATE_ROTATION_EXIT COUNTS stage=$stage enables=$enables disables=1 addresses=$address-count closes=1"

class Radio implements transport.Transport:
  owner_/Provider
  stage_/int
  radio_/esp32.Esp32Transport ::= esp32.Esp32Transport
  release_/monitor.Latch ::= monitor.Latch
  held/monitor.Latch ::= monitor.Latch
  holding/bool := false
  held-at/int := 0
  holds/int := 0
  closes/int := 0
  enables/int := 0
  disables/int := 0
  address-count/int := 0
  data-count/int := 0
  response-count/int := 0
  target_/int := 0
  constructor .owner_ .stage_:

  receive -> ByteArray:
    packet := radio_.receive
    if target_ != 0 and packet.size >= 6 and packet[0] == 4 and packet[1] == 14 and
        packet[4] | (packet[5] << 8) == target_:
      if packet.size != 7 or packet[6] != 0: throw "PRIVATE_ROTATION_EXIT_COMMAND_REJECTED"
      target_ = 0
      holds++
      holding = true
      held-at = Time.monotonic-us
      print "PRIVATE_ROTATION_EXIT HELD stage=$stage_ status=0"
      held.set true
      try:
        release_.get
      finally:
        holding = false
    return packet

  close -> none:
    closes++
    if not release_.has-value: release_.set true
    radio_.close

  send packet/ByteArray -> none:
    send-if packet: true

  send-if packet/ByteArray [allowed] -> bool:
    if not (radio_.send-if packet allowed): return false
    if closes != 0: throw "PRIVATE_ROTATION_EXIT_COMMAND_AFTER_CLOSE"
    if packet.size < 4 or packet[0] != 1: return true
    opcode := packet[1] | (packet[2] << 8)
    if opcode == 0x2008: data-count++
    if opcode == 0x2009: response-count++
    if opcode == 0x2005:
      address-count++
      address := packet[4..].copy
      if not (privacy.resolves (ByteArray 16: it + 1) address 1): throw "PRIVATE_ROTATION_EXIT_INVALID_RPA"
      if owner_.addresses.contains address: throw "PRIVATE_ROTATION_EXIT_REUSED_RPA"
      owner_.addresses.add address
      if stage_ == 1 and address-count == 2: target_ = opcode
    if opcode == 0x200a:
      if packet[4] == 1:
        enables++
        if stage_ == 2 and enables == 2: target_ = opcode
      else:
        disables++
        if stage_ == 0 and disables == 1: target_ = opcode
    return true
