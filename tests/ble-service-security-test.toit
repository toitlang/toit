// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.acl
import ble.experimental.bond
import ble.experimental.bond-table
import ble.experimental.bond-registry
import ble.experimental.bond-resume
import ble.experimental.central
import ble.experimental.encryption
import ble.experimental.hci
import ble.experimental.pairing-attempts as retry
import ble.experimental.privacy
import ble.experimental.security-owner show Owner
import ble.experimental.smp-identity
import ble.experimental.signaling
import ble.experimental.smp-pairing as smp
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import expect show *
import monitor
import system
import .ble-fixture as fixture
import .ble-key-reply-test as keys
import .ble-peripheral-test as peripheral
import .ble-security-test as wire
import .ble-bond-table-test as storage
import .ble-receive-flow-fixture as flow

main:
  with-timeout --ms=10_000:
    retry-provider-guard
    [false, true].do: | receive-flow/bool |
      [false, true].do: | random-address/bool |
        [0, 1, 3].do: | capability/int | run capability --random-address=random-address --receive-flow=receive-flow
        run 1 --close-during-confirmation --random-address=random-address --receive-flow=receive-flow
      [false, true].do: | authenticated/bool | resumed-service authenticated --receive-flow=receive-flow

resumed-service authenticated/bool --receive-flow/bool=false:
  provider := ResumeProvider authenticated --receive-flow=receive-flow
  ended := monitor.Latch
  responder := task::
    try:
      radio := provider.radio
      flow.initialize radio receive-flow
      peripheral.setup radio --local-random-address=provider.address
      event := fixture.connection-event.copy
      event[7] = 1
      event.replace 9 (privacy.from-prand provider.candidate.peer.irk #[0x42, 3, 4])
      // Both events arrive before the service's accept call returns. A late
      // owner installation would send a negative key reply and fail this test.
      radio.received.add event
      radio.received.add keys.request
      key-replied := false
      disabled := false
      parameters-sent := false
      // A key request can win command serialization before the redundant
      // advertising disable. Both HCI replies must be checked, while parameter
      // signaling starts only after accept has consumed the disable reply.
      3.repeat:
        packet := radio.sent.take
        if packet == #[1, 0x0a, 0x20, 1, 0]:
          expect (not disabled)
          radio.received.add #[4, 14, 4, 1, 0x0a, 0x20, 0]
          disabled = true
        else if packet[0] == 1:
          expect (not key-replied)
          expect-equals (hci.command-packet 0x201a (encryption.reply-parameters 0x234 keys.KEY)) packet
          radio.received.add #[4, 14, 6, 1, 0x1a, 0x20, 0, 0x34, 2]
          key-replied = true
        else:
          expect disabled
          expect (not parameters-sent)
          expect-equals (#[2, 0x34, 2, 16, 0, 12, 0, 5, 0] + (signaling.parameter-request 1)) packet
          radio.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]
          parameters-sent = true
      expect (disabled and key-replied and parameters-sent)
      radio.received.add (fixture.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
      radio.received.add (fixture.att-event #[0x0a, 12, 0])
      fixture.att-sent radio #[1, 0x0a, 12, 0, 5]
      radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
      provider.secured.get
      radio.received.add (fixture.att-event #[0x0a, 12, 0])
      fixture.att-sent radio #[0x0b, 42]
      radio.received.add (fixture.att-event #[0x0a, 14, 0])
      fixture.att-sent radio (authenticated ? #[0x0b, 43] : #[1, 0x0a, 14, 0, 5])
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    finally:
      critical-do --no-respect-deadline: ended.set true
  provider.install
  try:
    spawn:: application --observe-authenticated=authenticated
    provider.uninstall --wait
    ended.get
    expect provider.radio.closed
    flow.check provider.radio
    expect provider.secured.has-value
    provider.records.allow-read = true
    provider.registry.remove 0
    expect-equals [] provider.table.occupied
  finally:
    responder.cancel
    provider.uninstall
    provider.registry.close

class ResumeProvider extends providers.Provider:
  radio/fixture.FakeTransport
  receive-flow_/bool
  secured/monitor.Latch ::= monitor.Latch
  candidate/bond.Candidate
  address/ByteArray
  table/bond-table.Table
  registry/bond-registry.Registry
  records/GuardedRecords

  constructor authenticated/bool --receive-flow/bool=false:
    receive-flow_ = receive-flow
    radio = receive-flow ? flow.Radio : fixture.FakeTransport
    local := smp-identity.Identity (ByteArray 16 --initial=1) #[1, 2, 3, 4, 5, 6] 0
    peer := smp-identity.Identity (ByteArray 16 --initial=2) #[6, 5, 4, 3, 2, 1] 0
    candidate = bond.Candidate keys.KEY local peer --authenticated=authenticated
    backend := storage.MemoryRecords {:}
    table = bond-table.Table backend (ByteArray 32 --initial=42) --capacity=1
    expect-equals 0 (table.add candidate)
    table.close
    records = GuardedRecords backend.entries
    table = bond-table.Table records (ByteArray 32 --initial=42) --capacity=1
    registry = bond-registry.Registry table
    address = privacy.from-prand local.irk #[0x41, 2, 3]
    super

  receive-acl-packets -> int: return receive-flow_ ? 4 : 0
  open-transport -> transport.Transport: return radio
  local-random-address -> ByteArray?: return address
  create-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    // The registry already authenticated storage. Reject any further read
    // while an immediate LTK request can arrive at the connection hook.
    records.allow-read = false
    return ResumeHost controller info receive-limit registry
  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    return (host as ResumeHost).owner
  run-security-owner owner/Owner -> none:
    (owner as bond-resume.Resume).run
    secured.set true

class ResumeHost extends central.Central:
  registry_/bond-registry.Registry
  owner/bond-resume.Resume? := null

  constructor controller/hci.Controller info/hci.Capabilities receive-limit/int .registry_:
    super controller --acl-length=info.acl-length --acl-count=info.acl-count --receive-limit=receive-limit

  on-connected link/central.Link -> none:
    owner = registry_.resume this link --local-address=link.local-random-address
    system.process-stats --gc

class GuardedRecords extends storage.MemoryRecords:
  allow-read/bool := true

  constructor entries/Map: super entries

  read name/string -> ByteArray?:
    expect allow-read
    return super name

run capability/int --close-during-confirmation/bool=false --random-address/bool=false --receive-flow/bool=false:
  provider := Provider capability close-during-confirmation --receive-flow=receive-flow
  if random-address: provider.address = #[0xaa, 0xfb, 0x0d, 0x94, 0x81, 0x70]
  local-context := random-address
      ? #[1, 0x70, 0x81, 0x94, 0x0d, 0xfb, 0xaa]
      : #[0, 6, 5, 4, 3, 2, 1]
  ended := monitor.Latch
  numeric := capability == 1
  peer := smp.Session --initiator --io-capability=(numeric ? 1 : 3)
      --require-authentication=numeric
      --local-address=#[1, 6, 5, 4, 3, 2, 1]
      --peer-address=local-context
  responder := task::
    try:
      respond provider peer capability numeric close-during-confirmation
    finally:
      critical-do --no-respect-deadline: ended.set true
  provider.install
  try:
    spawn:: application --close-during-confirmation=close-during-confirmation
    provider.uninstall --wait
    ended.get
    expect-equals (numeric ? 1 : 0) provider.confirmations
    expect provider.radio.closed
    flow.check provider.radio
    expect-equals 1 provider.address-selections
    if close-during-confirmation:
      while not provider.confirmation-exited: sleep --ms=1
  finally:
    responder.cancel
    peer.close
    provider.uninstall

respond provider/Provider peer/smp.Session capability/int numeric/bool close-during-confirmation/bool:
  radio := provider.radio
  flow.initialize radio (provider.receive-acl-packets > 0)
  keys.establish radio --local-random-address=provider.address
  // The provider may reuse its policy buffer; pairing must use the link snapshot.
  if provider.address: provider.address.fill 0
  fixture.att-sent radio (signaling.parameter-request 1) --channel=5
  radio.received.add (fixture.att-event #[0x13, 1, 2, 0, 0, 0] --channel=5)
  radio.received.add (fixture.att-event #[0x0a, 12, 0])
  fixture.att-sent radio #[1, 0x0a, 12, 0, 5]
  if capability == 0:
    wire.send-smp radio peer.start
    expect-equals #[5, 5] (wire.take-smp radio (acl.Reassembler 0x234 --limit=65))
  else:
    wire.send-smp radio peer.start
    reassembler := acl.Reassembler 0x234 --limit=65
    while not peer.verified:
      wire.send-smp radio (peer.receive (wire.take-smp radio reassembler))
      if peer.comparison-number != null:
        provider.number = peer.comparison-number
        wire.send-smp radio (peer.approve true)
        if close-during-confirmation:
          while not radio.closed: sleep --ms=1
          // Leave the responder task without emitting a verified key.
          break
    if close-during-confirmation: return
    radio.received.add keys.request
    expected := hci.command-packet 0x201a (encryption.reply-parameters 0x234 peer.key)
    fixture.reply radio expected #[0x34, 2]
    radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
    // The protocol owner requires its pairing worker to consume encryption
    // completion before exposing security. Requests may briefly see 0x0f.
    while true:
      radio.received.add (fixture.att-event #[0x0a, 12, 0])
      response := radio.sent.take
      radio.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]
      if response[9..] == #[0x0b, 42]: break
      expect-equals #[1, 0x0a, 12, 0, 0x0f] response[9..]
      sleep --ms=2
  radio.received.add (fixture.att-event #[0x0a, 14, 0])
  fixture.att-sent radio (numeric ? #[0x0b, 43] : #[1, 0x0a, 14, 0, 5])
  radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]

application --close-during-confirmation/bool=false --observe-authenticated/bool?=null:
  client := clients.Client
  client.open
  try:
    session := client.configure
    session.add-service #[0xf0, 0xff]
    expect-equals 12 (session.add-characteristic #[0xf1, 0xff] --read --encrypted --value=#[42]
        --dynamic-read=(observe-authenticated != null))
    expect-equals 14 (session.add-characteristic #[0xf2, 0xff] --read --authenticated --value=#[43])
    session.start #[2, 1, 6]
    session.peer
    if close-during-confirmation:
      sleep --ms=100
      return
    observed/clients.SecuritySnapshot? := null
    session.serve
        (: | request/clients.Request |
          expect (observe-authenticated != null)
          expect-equals 12 request.handle
          expect-equals null observed
          observed = session.security
          expect (observed.paired and observed.encrypted)
          expect-equals observe-authenticated observed.authenticated
          request.reply #[42])
        (: unreachable)
        (: unreachable)
    if observe-authenticated != null:
      // The resumed link is now disconnected. A retained observation stays
      // immutable and cannot be confused with a fresh live security query.
      expect (observed != null)
      system.process-stats --gc
      expect (observed.paired and observed.encrypted)
      expect-equals observe-authenticated observed.authenticated
  finally:
    client.close

class Provider extends providers.Provider:
  radio/fixture.FakeTransport
  receive-flow_/bool
  address/ByteArray? := null
  address-selections/int := 0
  capability_/int
  number/int? := null
  confirmations/int := 0
  close-during-confirmation_/bool
  confirmation-exited/bool := false

  constructor .capability_ .close-during-confirmation_ --receive-flow/bool=false:
    receive-flow_ = receive-flow
    radio = receive-flow ? flow.Radio : fixture.FakeTransport
    super

  receive-acl-packets -> int: return receive-flow_ ? 4 : 0
  open-transport -> transport.Transport: return radio
  local-random-address -> ByteArray?:
    address-selections++
    return address

  pairing-io-capability -> int?: return capability_ == 0 ? null : capability_
  require-authentication -> bool: return capability_ == 1

  confirm-pairing actual/int -> bool:
    confirmations++
    while number == null: sleep --ms=1
    expect-equals number actual
    try:
      if close-during-confirmation_: (monitor.Latch).get
      return true
    finally:
      confirmation-exited = true

// Admission failures must reach the application through the service boundary,
// before this fresh owner sends SMP or exposes an encrypted connection.
retry-provider-guard:
  provider := RetryProvider
  expect-throw "PREVIOUS_PAIRING_FAILED":
    provider.pairing-attempts.with-attempt #[1, 1, 2, 3, 4, 5, 6]:
      throw "PREVIOUS_PAIRING_FAILED"
  system.process-stats --gc
  responder := task::
    flow.initialize provider.radio false
    keys.establish provider.radio
  provider.install
  try:
    expect-throw "SMP_REPEATED_ATTEMPTS": application
    expect provider.radio.closed
    expect-equals 0 provider.radio.smp-packets
  finally:
    responder.cancel
    provider.uninstall

class RetryProvider extends providers.Provider:
  radio/RetryRadio ::= RetryRadio
  attempts/retry.Attempts ::= retry.Attempts --minimum=(Duration --s=10)
  constructor: super
  open-transport -> transport.Transport: return radio
  pairing-io-capability -> int?: return 3
  pairing-attempts -> retry.Attempts: return attempts

class RetryRadio extends fixture.FakeTransport:
  smp-packets/int := 0
  constructor: super
  send packet/ByteArray -> none:
    if packet.size >= 9 and packet[0] == 2 and packet[7] == 6 and packet[8] == 0:
      smp-packets++
    super packet
