// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.bond
import ble.experimental.bond-resume
import ble.experimental.central
import ble.experimental.connection
import ble.experimental.encryption
import ble.experimental.hci
import ble.experimental.privacy
import ble.experimental.security-owner show Owner
import ble.experimental.smp-identity
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import .ble-hci-test as fixture
import .ble-key-reply-test as keys
import .ble-receive-flow-fixture as flow

main:
  with-timeout --ms=10_000:
    [false, true].do: | receive-flow/bool |
      [false, true].do: | private/bool |
        [false, true].do: | authenticated/bool | run private authenticated false --receive-flow=receive-flow
        run private false true --receive-flow=receive-flow

run private/bool authenticated/bool reject/bool --receive-flow/bool=false:
  provider := Provider private authenticated --receive-flow=receive-flow
  provider.install
  client := clients.Client
  client.open
  submitted := monitor.Latch
  allow := monitor.Latch
  result := monitor.Latch
  responder := task::
    radio := provider.radio
    flow.initialize radio receive-flow
    if private: fixture.reply radio (hci.command-packet 0x2005 provider.local) #[]
    parameters := connection.create-parameters provider.peer --address-type=(private ? 1 : 0)
        --own-address-type=(private ? 1 : 0)
    fixture.status-reply radio (hci.command-packet 0x200d parameters)
    event := fixture.connection-event.copy
    event[8] = private ? 1 : 0
    event.replace 9 provider.peer
    radio.received.add event
    // The client exchanges its MTU first; the peer's answer proves its host
    // finished connection setup. Resume then submits encryption with the
    // saved key, without fresh SMP.
    fixture.gatt-reply radio #[2, 23, 0] #[3, 23, 0]
    fixture.status-reply radio (hci.command-packet 0x2019 (encryption.enable-parameters 0x234 keys.KEY))
    submitted.set true
    allow.get
    radio.received.add #[4, 8, 4, reject ? 6 : 0, 0x34, 2, reject ? 0 : 1]
    if not reject:
      radio.received.add (fixture.att-event #[1, 3, 0, 0, 16, 0, 0] --channel=6)
      fixture.att-sent radio #[5, 5] --channel=6
      fixture.gatt-reply radio #[0x0a, 3, 0] #[0x0b, 42]
      fixture.status-reply radio #[1, 6, 4, 3, 0x34, 2, 0x13]
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
  caller := task::
    error := catch: result.set (client.connect provider.peer --address-type=(private ? 1 : 0))
    if error: result.set error --exception
  connected/clients.Connection? := null
  try:
    submitted.get
    expect (not result.has-value)
    expect (not provider.owner.paired and not provider.owner.encrypted)
    system.process-stats --gc
    allow.set true
    if reject:
      expect-equals (encryption.Error 6).stringify (catch: result.get)
    else:
      connected = result.get
      expect provider.owner.paired
      expect provider.owner.encrypted
      expect-equals authenticated provider.owner.authenticated
      expect-equals #[42] (connected.read 3)
      connected.disconnect
    while not provider.radio.closed: sleep --ms=1
    expect (not provider.owner.paired and not provider.owner.authenticated)
    expect-equals keys.KEY provider.saved.key
    if reject and receive-flow:
      // Only the MTU exchange preceding encryption produced incoming ACL.
      expect-equals 1 (provider.radio as flow.Radio).received-acl
      expect-equals 1 (provider.radio as flow.Radio).returned
    else:
      flow.check provider.radio
  finally:
    allow.set true
    if connected: connected.close
    caller.cancel
    responder.cancel
    client.close
    provider.uninstall

class Provider extends providers.Provider:
  radio/fixture.FakeTransport
  receive-flow_/bool
  owner/bond-resume.Resume? := null
  saved/bond.Candidate
  local/ByteArray
  peer/ByteArray
  private_/bool

  constructor .private_ authenticated/bool --receive-flow/bool=false:
    receive-flow_ = receive-flow
    radio = receive-flow ? flow.Radio : fixture.FakeTransport
    local-id := smp-identity.Identity (ByteArray 16 --initial=1) #[1, 2, 3, 4, 5, 6] 0
    peer-id := smp-identity.Identity (ByteArray 16 --initial=2) #[6, 5, 4, 3, 2, 1] 0
    saved = bond.Candidate keys.KEY local-id peer-id --authenticated=authenticated
    local = private_ ? (privacy.from-prand local-id.irk #[0x41, 2, 3]) : local-id.address
    peer = private_ ? (privacy.from-prand peer-id.irk #[0x42, 3, 4]) : peer-id.address
    super

  receive-acl-packets -> int: return receive-flow_ ? 4 : 0
  open-transport -> transport.Transport: return radio
  central-local-random-address info/hci.Capabilities -> ByteArray?: return private_ ? local : null
  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    owner = bond-resume.Resume host link saved --local-address=(link.local-random-address or info.address)
        --require-authentication=saved.authenticated
    return owner
  run-central-security-owner selected/Owner -> none:
    (selected as bond-resume.Resume).run
