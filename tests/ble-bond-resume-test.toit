// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.att
import ble.experimental.bond
import ble.experimental.bond-resume
import ble.experimental.bond-registry
import ble.experimental.bond-table
import ble.experimental.central
import ble.experimental.connection
import ble.experimental.encryption
import ble.experimental.hci
import ble.experimental.privacy
import ble.experimental.smp-identity
import expect show *
import monitor
import system
import .ble-hci-test as fixture
import .ble-key-reply-test as keys
import .ble-peripheral-test as peripheral-fixture
import .ble-bond-table-test as storage

main:
  with-timeout --ms=10_000:
    immediate-key-request
    [false, true].do: | managed/bool |
      [false, true].do: | peripheral/bool |
        [false, true].do: | authenticated/bool |
          run "success" --peripheral=peripheral --authenticated=authenticated --managed=managed
          run "success" --peripheral=peripheral --authenticated=authenticated --private --managed=managed
        ["wrong-key", "disabled", "timeout", "cancel"].do: | mode/string |
          run mode --peripheral=peripheral --managed=managed

run mode/string --peripheral/bool=false --authenticated/bool=false --private/bool=false
    --managed/bool=false:
  local-id := smp-identity.Identity (ByteArray 16 --initial=1) #[6, 5, 4, 3, 2, 1] 0
  peer-id := smp-identity.Identity (ByteArray 16 --initial=2) #[1, 2, 3, 4, 5, 6] 0
  local := private ? (privacy.from-prand local-id.irk #[0x41, 2, 3]) : local-id.address
  peer := private ? (privacy.from-prand peer-id.irk #[0x42, 3, 4]) : peer-id.address
  candidate := bond.Candidate keys.KEY local-id peer-id --authenticated=authenticated
  registry/bond-registry.Registry? := null
  if managed:
    table := bond-table.Table (storage.MemoryRecords {:}) (ByteArray 32 --initial=42) --capacity=1
    registry = bond-registry.Registry table
    expect-equals 0 (registry.add candidate)
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio)
  started := monitor.Latch
  accepted := monitor.Latch
  rejected := monitor.Latch
  allow := monitor.Latch
  ended := monitor.Latch
  responder := task::
    try:
      if peripheral:
        peripheral-fixture.setup radio --local-random-address=(private ? local : null)
      else:
        if private: fixture.reply radio (hci.command-packet 0x2005 local) #[]
        parameters := connection.create-parameters peer --address-type=(private ? 1 : 0)
            --own-address-type=(private ? 1 : 0)
        fixture.status-reply radio (hci.command-packet 0x200d parameters)
      event := fixture.connection-event.copy
      event[7] = peripheral ? 1 : 0
      event[8] = private ? 1 : 0
      event.replace 9 peer
      radio.received.add event
      if peripheral: peripheral-fixture.reply radio 0x200a #[0]
      started.get
      if peripheral:
        radio.received.add keys.request
        fixture.reply radio (hci.command-packet 0x201a (encryption.reply-parameters 0x234 keys.KEY)) #[0x34, 2]
      else:
        fixture.status-reply radio (hci.command-packet 0x2019 (encryption.enable-parameters 0x234 keys.KEY))
      accepted.set true
      allow.get
      if mode == "success":
        radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
        radio.received.add (fixture.att-event #[1, 3, 0, 0, 16, 0, 0] --channel=6)
        fixture.att-sent radio #[5, 5] --channel=6
        rejected.set true
        fixture.gatt-reply radio #[0x0a, 1, 0] #[0x0b, 42]
      else:
        if mode == "wrong-key": radio.received.add #[4, 8, 4, 6, 0x34, 2, 0]
        if mode == "disabled": radio.received.add #[4, 8, 4, 0, 0x34, 2, 0]
        while not radio.closed: sleep --ms=1
    finally:
      critical-do --no-respect-deadline: ended.set true
  client/att.Client? := null
  worker/Task? := null
  result := monitor.Latch
  try:
    link := peripheral
        ? (host.accept #[2, 1, 6] --local-random-address=(private ? local : null))
        : (host.connect peer --address-type=(private ? 1 : 0) --local-random-address=(private ? local : null))
    wrong-local := bond.Candidate keys.KEY peer-id peer-id --authenticated
    expect-throw "BLE_BOND_WRONG_LOCAL_IDENTITY": bond-resume.Resume host link wrong-local --local-address=local
    wrong-peer := bond.Candidate keys.KEY local-id local-id --authenticated
    expect-throw "BLE_BOND_WRONG_PEER_IDENTITY": bond-resume.Resume host link wrong-peer --local-address=local
    if not authenticated:
      expect-throw "BLE_BOND_INSUFFICIENT_AUTHENTICATION":
        if registry:
          registry.resume host link --local-address=local --require-authentication
        else:
          bond-resume.Resume host link candidate --local-address=local --require-authentication
      expect link.connected
    resume := registry
        ? (registry.resume host link --local-address=local --require-authentication=authenticated)
        : (bond-resume.Resume host link candidate --local-address=local --require-authentication=authenticated)
    client = att.Client host link --pairing=resume
    database := attributes.Database
    database.add-service #[0xf0, 0xff]
    database.add-characteristic #[0xf1, 0xff] --read --encrypted --value=#[10]
    database.add-characteristic #[0xf2, 0xff] --read --authenticated --value=#[20]
    permissions := database.session --security=resume
    expect-equals #[1, 0x0a, 3, 0, 5] (permissions.request #[0x0a, 3, 0])
    expect-equals #[1, 0x0a, 5, 0, 5] (permissions.request #[0x0a, 5, 0])
    expect (not resume.paired and not resume.encrypted and not resume.authenticated)
    worker = task::
      started.set true
      error := catch: resume.run --timeout=(Duration --ms=(mode == "timeout" ? 30 : 2_000))
      result.set error
    accepted.get
    expect (not resume.paired and not resume.encrypted and not resume.authenticated)
    if not peripheral:
      // The controller accepted encryption setup, but has not completed it.
      // Core 6.3, Vol 3, Part H, 2.4.6 requires ignoring Security Requests
      // in this window, even if they ask for stronger security or set RFU bits.
      sent := radio.sent-count
      [0, 4, 8, 0x0d, 0xff].do: | auth/int |
        resume.receive #[0x0b, auth]
        expect-equals sent radio.sent-count
      if mode == "success":
        radio.received.add (fixture.att-event #[0x0b, 0x0d] --channel=6)
        radio.received.add (fixture.att-event #[0x1b, 7, 0, 77])
        notification := client.receive-notification
        expect-equals #[77] notification.value
        expect-equals sent radio.sent-count
        expect (not resume.encrypted and not resume.authenticated)
    allow.set true
    if mode == "cancel": worker.cancel
    if mode == "success":
      expect-null result.get
      expect resume.paired
      expect resume.encrypted
      expect-equals authenticated resume.authenticated
      expect-equals #[0x0b, 10] (permissions.request #[0x0a, 3, 0])
      expect-equals (authenticated ? #[0x0b, 20] : #[1, 0x0a, 5, 0, 5]) (permissions.request #[0x0a, 5, 0])
      system.process-stats --gc
      rejected.get
      expect-equals #[42] (client.read 1)
      expect-throw "BLE_BOND_RESUME_INVALID_STATE": resume.run
      expect-throw "BLE_BOND_REQUIRES_FRESH_LINK": bond-resume.Resume host link candidate --local-address=local
      radio.received.add #[4, 8, 4, 0, 0x34, 2, 0]
    else if mode != "cancel":
      error := result.get
      if mode == "wrong-key":
        expect (error is encryption.Error)
        expect-equals 6 error.status
      else:
        expect-equals (mode == "timeout" ? "DEADLINE_EXCEEDED" : "HCI_ENCRYPTION_NOT_ENABLED") error
    while link.connected: sleep --ms=1
    expect (not resume.paired and not resume.encrypted and not resume.authenticated)
    expect radio.closed
    expect-equals #[1, 0x0a, 3, 0, 5] (permissions.request #[0x0a, 3, 0])
    expect-equals #[1, 0x0a, 5, 0, 5] (permissions.request #[0x0a, 5, 0])
    client.close
    ended.get
    if registry:
      // With the tracking slot released, admission reaches fresh-link validation
      // instead of failing with BLE_BOND_OWNER_LIMIT.
      expect-throw "HCI_INVALID_LINK": registry.resume host link --local-address=local
      // An encryption failure closes its owner, not the trusted bond store.
      registry.remove 0
      expect-equals 0 (registry.add candidate)
  finally:
    if worker: worker.cancel
    if client: client.close
    responder.cancel
    host.close
    host.wait-closed
    if registry: registry.close

immediate-key-request:
  local := smp-identity.Identity (ByteArray 16) #[6, 5, 4, 3, 2, 1] 0
  peer := smp-identity.Identity (ByteArray 16) #[1, 2, 3, 4, 5, 6] 0
  candidate := bond.Candidate keys.KEY local peer --authenticated
  radio := fixture.FakeTransport
  host := PreparedHost radio candidate
  encrypted := monitor.Latch
  responder := task::
    peripheral-fixture.setup radio
    event := fixture.connection-event.copy
    event[7] = 1
    event[8] = 0
    // No application task runs between queueing these controller events.
    radio.received.add event
    radio.received.add keys.request
    peripheral-fixture.reply radio 0x200a #[0]
    fixture.reply radio (hci.command-packet 0x201a (encryption.reply-parameters 0x234 keys.KEY)) #[0x34, 2]
    radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
    encrypted.set true
    fixture.gatt-reply radio #[0x0a, 1, 0] #[0x0b, 42]
  client/att.Client? := null
  try:
    link := host.accept #[2, 1, 6]
    resume := host.resume
    expect (resume != null)
    expect-equals 1 host.hooks
    client = att.Client host link --pairing=resume
    encrypted.get
    while not link.encrypted: sleep --ms=1
    // The installed key already served the immediate request, but only run
    // grants this owner's application permissions after checking the result.
    expect (not resume.encrypted and not resume.authenticated)
    resume.run
    expect resume.encrypted
    expect resume.authenticated
    expect-equals #[42] (client.read 1)
  finally:
    if client: client.close
    responder.cancel
    host.close
    host.wait-closed

class PreparedHost extends central.Central:
  candidate_/bond.Candidate
  resume/bond-resume.Resume? := null
  hooks/int := 0

  constructor radio/fixture.FakeTransport .candidate_:
    super (hci.Controller radio)

  on-connected link/central.Link -> none:
    hooks++
    resume = bond-resume.Resume this link candidate_ --local-address=candidate_.local.address
    system.process-stats --gc
