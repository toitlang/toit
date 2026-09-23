// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.acl
import ble.experimental.central
import ble.experimental.encryption
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.security-owner show Owner
import ble.experimental.smp-pairing as smp
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import .ble-fixture as fixture
import .ble-security-test as wire
import .ble-receive-flow-fixture as flow

main:
  with-timeout --ms=15_000:
    [false, true].do: | receive-flow/bool |
      [false, true].do: | numeric/bool |
        [false, true].do: | random/bool | run numeric random --receive-flow=receive-flow

run numeric/bool random/bool --receive-flow/bool=false:
  provider := Provider numeric random --receive-flow=receive-flow
  provider.install
  provider.radio.auto-disconnect = true
  client := clients.Client
  client.open
  submitted := monitor.Latch
  encrypt := monitor.Latch
  connected := monitor.Latch
  responder := task::
    radio := provider.radio
    flow.initialize radio receive-flow --acl-length=27
    command := fixture.create-command.copy
    if random:
      fixture.reply radio (hci.command-packet 0x2005 provider.local) #[]
      command[16] = 1
    fixture.status-reply radio command
    radio.received.add fixture.connection-event
    reassembler := acl.Reassembler 0x234 --limit=65
    while not provider.peer.verified:
      wire.send-smp radio (provider.peer.receive (wire.take-smp radio reassembler))
    fixture.status-reply radio
        hci.command-packet 0x2019 (encryption.enable-parameters 0x234 provider.peer.key)
    submitted.set true
    encrypt.get
    radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
    fixture.gatt-reply radio #[0x0a, 3, 0] #[0x0b, 42]
  caller := task::
    error := catch: connected.set (client.connect #[1, 2, 3, 4, 5, 6] --address-type=1
        --require-encryption
        --require-authentication=numeric)
    if error: connected.set error --exception
  connection/clients.Connection? := null
  try:
    submitted.get
    expect (not connected.has-value)
    expect (not provider.owner.encrypted and not provider.owner.authenticated)
    encrypt.set true
    connection = connected.get
    expect provider.owner.paired
    expect provider.owner.encrypted
    expect-equals numeric provider.owner.authenticated
    expect-equals (numeric ? 1 : 0) provider.confirmations
    value := connection.read 3
    system.process-stats --gc
    expect-equals #[42] value
    // Losing established encryption invalidates the connection even while idle.
    provider.radio.received.add #[4, 8, 4, 0, 0x34, 2, 0]
    while provider.radio.disconnects == 0: sleep --ms=1
    expect (not provider.owner.encrypted and not provider.owner.authenticated)
    expect-throw "HCI_ENCRYPTION_LOST": connection.read 3
    flow.check provider.radio
  finally:
    encrypt.set true
    if connection: connection.close
    caller.cancel
    responder.cancel
    client.close
    provider.uninstall
    provider.peer.close

class Provider extends providers.Provider:
  radio/fixture.FakeTransport
  receive-flow_/bool
  owner/security.Pairing? := null
  peer/smp.Session
  local/ByteArray
  confirmations/int := 0
  numeric_/bool
  random_/bool

  constructor .numeric_ .random_ --receive-flow/bool=false:
    receive-flow_ = receive-flow
    radio = receive-flow ? flow.Radio : fixture.FakeTransport
    local = random_ ? #[1, 0x30, 0x23, 0xf2, 0x3a, 0xc8] : #[1, 2, 3, 4, 5, 6]
    peer = smp.Session --no-initiator --io-capability=(numeric_ ? 1 : 3)
        --require-authentication=numeric_
        --local-address=#[1, 6, 5, 4, 3, 2, 1]
        --peer-address=(#[(random_ ? 1 : 0)] + local.reverse)
    super

  receive-acl-packets -> int: return receive-flow_ ? 4 : 0

  open-transport -> transport.Transport: return radio
  central-local-random-address info/hci.Capabilities -> ByteArray?: return random_ ? local : null
  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    owner = security.Pairing host link --local-address=(link.local-random-address or info.address)
        --local-address-type=(link.local-random-address ? 1 : 0)
        --attempts=pairing-attempts
        --attempt-identity=(pairing-peer-identity link)
        --io-capability=(numeric_ ? 1 : 3)
        --require-authentication=numeric_
    return owner
  run-central-security-owner selected/Owner -> none:
    (selected as security.Pairing).run: | number/int |
      expect numeric_
      expect-equals peer.comparison-number number
      confirmations++
      system.process-stats --gc
      wire.send-smp radio (peer.approve true)
      true
