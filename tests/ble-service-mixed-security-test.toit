// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.acl
import ble.experimental.central
import ble.experimental.encryption
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.security-owner show Owner
import ble.experimental.service.client as clients
import ble.experimental.service.provider as rpc
import ble.experimental.smp-pairing as smp
import expect show *
import io
import monitor
import system
import .ble-connect-isolation-test as connect
import .ble-hci-test as packets
import .ble-key-reply-test as keys
import .ble-multilink-test as links
import .ble-service-mixed-test as mixed
import .ble-service-multiclient-test as wire

main:
  [false, true].do: | peripheral-first/bool |
    [false, true].do: | central-numeric/bool |
      [false, true].do: | peripheral-numeric/bool |
        [false, true].do: | lose-central/bool |
          with-timeout --ms=10_000: run peripheral-first central-numeric peripheral-numeric lose-central
  with-timeout --ms=10_000: reject-central-requirement

reject-central-requirement:
  provider := Provider false true
  provider.install
  central-client := clients.Client
  peripheral-client := clients.Client
  central-client.open
  peripheral-client.open
  checked := monitor.Latch
  responder := task::
    mixed.initialize provider.radio
    host/central.Central := provider.ready.get
    pair-peripheral provider
    connect.establish provider.radio host 1 0x234 --extended-mode
    pair provider 0
    // Authentication on the other role cannot satisfy this application's
    // requirement. Reject before the connection scope or any ATT read.
    wire.disconnect provider.radio 0x234
    protected-read provider
    checked.set true
    wire.disconnect provider.radio 0x235
  try:
    p := peripheral peripheral-client
    (provider.secured[1] as monitor.Latch).get
    expect-throw "GATT_CENTRAL_SECURITY_REQUIRED":
      central-client.with-connection (links.address 1) --address-type=1
          --require-authentication: unreachable
    while not provider.last-central.is-released: sleep --ms=1
    expect (not provider.radio.closed)
    checked.get
    expect p.security.authenticated
    p.close
    while not provider.last-peripheral.is-released: sleep --ms=1
    expect provider.radio.closed
    expect-equals 1 provider.opens
    expect-equals 1 provider.radio.closes
  finally:
    central-client.close
    peripheral-client.close
    provider.uninstall
    responder.cancel
    provider.peers.do: (it as smp.Session).close

run peripheral-first/bool central-numeric/bool peripheral-numeric/bool lose-central/bool:
  provider := Provider central-numeric peripheral-numeric
  provider.install
  central-client := clients.Client
  peripheral-client := clients.Client
  central-client.open
  peripheral-client.open
  ready := monitor.Latch
  lose := monitor.Latch
  survivor-read := monitor.Latch
  responder := task::
    mixed.initialize provider.radio
    host/central.Central := provider.ready.get
    if peripheral-first: pair-peripheral provider
    connect.establish provider.radio host 1 0x234 --extended-mode
    pair provider 0
    if not peripheral-first: pair-peripheral provider
    wire.sent provider.radio 0x234 #[0x0a, 3, 0]
    wire.incoming provider.radio 0x234 #[0x0b, 41]
    protected-read provider
    ready.set true
    lose.get
    index := lose-central ? 0 : 1
    encryption-event provider.radio (0x234 + index) false
    wire.disconnect provider.radio (0x234 + index)
    if lose-central:
      protected-read provider
      survivor-read.set true
      wire.disconnect provider.radio 0x235
    else:
      wire.sent provider.radio 0x234 #[0x0a, 3, 0]
      wire.incoming provider.radio 0x234 #[0x0b, 42]
      wire.disconnect provider.radio 0x234
  try:
    p/clients.Session? := null
    if peripheral-first:
      p = peripheral peripheral-client
      (provider.secured[1] as monitor.Latch).get
    c := central-client.connect (links.address 1) --address-type=1
        --require-encryption
        --require-authentication=central-numeric
    if not p: p = peripheral peripheral-client
    (provider.secured[1] as monitor.Latch).get
    cs := c.security
    ps := p.security
    expect (cs.paired and cs.encrypted and ps.paired and ps.encrypted)
    expect-equals central-numeric cs.authenticated
    expect-equals peripheral-numeric ps.authenticated
    expect-equals #[41] (c.read 3)
    ready.get
    system.process-stats --gc
    expect-equals [central-numeric ? 1 : 0, peripheral-numeric ? 1 : 0] provider.confirmations
    lose.set true
    victim := lose-central ? provider.last-central : provider.last-peripheral
    if lose-central:
      while (provider.owners[0] as security.Pairing).encrypted: yield
      expect-throw "HCI_ENCRYPTION_LOST": c.read 3
      c.close
    else:
      expect-throw "HCI_ENCRYPTION_LOST": p.next
      p.close
    while not victim.is-released: sleep --ms=1
    expect (not provider.radio.closed)
    expect (provider.owners[lose-central ? 1 : 0] as security.Pairing).encrypted
    expect (not (provider.owners[lose-central ? 0 : 1] as security.Pairing).encrypted)
    // Retained observations are snapshots; live owners remain link-specific.
    system.process-stats --gc
    expect (cs.encrypted and ps.encrypted)
    if lose-central:
      survivor-read.get
      expect-equals peripheral-numeric p.security.authenticated
      p.close
      while not provider.last-peripheral.is-released: sleep --ms=1
    else:
      expect-equals #[42] (c.read 3)
      expect-equals central-numeric c.security.authenticated
      c.disconnect
    expect provider.radio.closed
    expect-equals 1 provider.opens
    expect-equals 1 provider.radio.closes
  finally:
    lose.set true
    central-client.close
    peripheral-client.close
    provider.uninstall
    responder.cancel
    provider.peers.do: (it as smp.Session).close

peripheral client/clients.Client -> clients.Session:
  session := client.configure
  session.add-service #[0xf0, 0xff]
  expect-equals 12 (session.add-characteristic #[0xf1, 0xff] --read --encrypted --value=#[42])
  expect-equals 14 (session.add-characteristic #[0xf2, 0xff] --read --authenticated --value=#[43])
  session.start #[2, 1, 6]
  session.peer
  return session

pair-peripheral provider/Provider:
  mixed.peripheral provider.radio
  // Even an authenticated central role must not unlock the peripheral role.
  wire.incoming provider.radio 0x235 #[0x0a, 12, 0]
  wire.sent provider.radio 0x235 #[1, 0x0a, 12, 0, 5]
  pair provider 1

protected-read provider/Provider:
  wire.incoming provider.radio 0x235 #[0x0a, 12, 0]
  wire.sent provider.radio 0x235 #[0x0b, 42]
  wire.incoming provider.radio 0x235 #[0x0a, 14, 0]
  wire.sent provider.radio 0x235 (provider.numeric[1] ? #[0x0b, 43] : #[1, 0x0a, 14, 0, 5])

pair provider/Provider index/int:
  radio := provider.radio
  peer/smp.Session := provider.peers[index]
  handle := 0x234 + index
  reassembler := acl.Reassembler handle --limit=65
  approved := false
  if index == 1: send-smp radio handle peer.start
  while not peer.verified:
    send-smp radio handle (peer.receive (take-smp radio handle reassembler))
    if peer.comparison-number != null and not approved:
      provider.numbers[index] = peer.comparison-number
      approved = true
      send-smp radio handle (peer.approve true)
  if index == 0:
    packets.status-reply radio (hci.command-packet 0x2019 (encryption.enable-parameters handle peer.key))
  else:
    request := keys.request
    io.LITTLE-ENDIAN.put-uint16 request 4 handle
    radio.received.add request
    packets.reply radio (hci.command-packet 0x201a (encryption.reply-parameters handle peer.key)) #[0x35, 2]
  encryption-event radio handle true
  (provider.secured[index] as monitor.Latch).get

encryption-event radio/packets.FakeTransport handle/int enabled/bool:
  event := #[4, 8, 4, 0, 0, 0, enabled ? 1 : 0]
  io.LITTLE-ENDIAN.put-uint16 event 4 handle
  radio.received.add event

take-smp radio/packets.FakeTransport handle/int reassembler/acl.Reassembler -> ByteArray:
  while true:
    packet := radio.sent.take.copy
    expect-equals 2 packet[0]
    if packet[2] & 0x30 == 0: packet[2] |= 0x20
    result := reassembler.accept packet
    links.completed radio handle
    if result:
      expect-equals 6 result.channel
      return result.payload

send-smp radio/packets.FakeTransport handle/int packets/List:
  packets.do: | bytes/ByteArray |
    pdu := #[bytes.size, 0, 6, 0] + bytes
    offset := 0
    while offset < pdu.size:
      end := min (offset + 27) pdu.size
      links.incoming radio handle pdu[offset..end] --start=(offset == 0)
      offset = end

class Provider extends mixed.Provider:
  numeric/List
  peers/List ::= []
  owners/List ::= [null, null]
  secured/List ::= [monitor.Latch, monitor.Latch]
  confirmations/List ::= [0, 0]
  numbers/List ::= [null, null]

  constructor central-numeric/bool peripheral-numeric/bool:
    numeric = [central-numeric, peripheral-numeric]
    2.repeat: | index/int |
      peers.add (smp.Session --initiator=(index == 1)
          --io-capability=(numeric[index] ? 1 : 3)
          --require-authentication=numeric[index]
          --local-address=(#[1] + (links.address (index + 1)).reverse)
          --peer-address=#[0, 6, 5, 4, 3, 2, 1])
    super

  create-builder client/int name/string -> rpc.Session:
    last-peripheral = super client name
    return last-peripheral

  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    return create-owner host link info 0

  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    return create-owner host link info 1

  create-owner host/central.Central link/central.Link info/hci.Capabilities index/int -> Owner:
    owner := security.Pairing host link --local-address=info.address
        --io-capability=(numeric[index] ? 1 : 3)
        --require-authentication=numeric[index]
    owners[index] = owner
    return owner

  run-central-security-owner selected/Owner -> none: run-owner selected 0
  run-security-owner selected/Owner -> none: run-owner selected 1

  run-owner selected/Owner index/int:
    (selected as security.Pairing).run: | number/int |
      expect numeric[index]
      while numbers[index] == null: sleep --ms=1
      expect-equals numbers[index] number
      confirmations[index]++
      system.process-stats --gc
      true
    (secured[index] as monitor.Latch).set true
