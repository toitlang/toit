// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.acl
import ble.experimental.att
import ble.experimental.attribute-server as attributes
import ble.experimental.gatt-server
import ble.experimental.central
import ble.experimental.encryption
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.pairing-attempts as retry
import ble.experimental.privacy as privacy
import ble.experimental.smp-pairing as smp
import ble.experimental.smp-features show PairingError
import expect show *
import monitor
import system
import .ble-fixture as fixture
import .ble-key-reply-test as key-fixture

main:
  with-timeout --ms=10_000:
    [false, true].do: | random-address/bool |
      success --no-numeric --random-address=random-address
      success --numeric --random-address=random-address
      peripheral-success --random-address=random-address
    [0, 1, 12, 15, 16].do: | reason/int |
      success --numeric --reject-at-encryption --rejection-reason=reason
    [#[5], #[5, 12, 0]].do: | packet/ByteArray |
      success --numeric --reject-at-encryption --rejection-packet=packet
    success --numeric --reject-at-encryption --rejection-packet=#[5] --no-complete-failure
    canceled
    canceled --explicit
    canceled --explicit --mapped
    attempts := retry.Attempts --minimum=(Duration --s=10)
    rejected --attempts=attempts
    blocked-pairing attempts
    rejected
    rejected --no-complete
    rejected --remote
    peripheral-success --failure=5
    peripheral-success --failure=-1

rejected --complete/bool=true --remote/bool=false --attempts/retry.Attempts?=null:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  peer := smp.Session --no-initiator --io-capability=1 --require-authentication
      --local-address=#[1, 6, 5, 4, 3, 2, 1]
      --peer-address=#[0, 1, 2, 3, 4, 5, 6]
  checked := monitor.Latch
  client/att.Client? := null
  responder := task::
    fixture.status-reply transport fixture.create-command
    transport.received.add fixture.connection-event
    reassembler := acl.Reassembler 0x234 --limit=65
    while peer.comparison-number == null:
      send-smp transport (peer.receive (take-smp transport reassembler))
    if not remote:
      // Withhold the failure packet's credit to model asynchronous radio output.
      packet := transport.sent.take.copy
      expect-equals 2 packet[0]
      packet[2] |= 0x20
      pdu := reassembler.accept packet
      expect-equals 6 pdu.channel
      expect-equals #[5, 12] pdu.payload
      sleep --ms=20
      expect (not transport.closed)
      if complete:
        transport.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]
    checked.set true
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
    pairing := security.Pairing host link --local-address=#[6, 5, 4, 3, 2, 1]
        --io-capability=1
        --require-authentication
        --attempts=attempts
    client = att.Client host link --pairing=pairing
    started := Time.monotonic-us
    error := catch: pairing.run: | number/int |
      expect-equals peer.comparison-number number
      if remote: send-smp transport (peer.approve false)
      remote
    if complete:
      expect (error is PairingError)
      expect-equals 12 error.reason
    else:
      expect-equals DEADLINE-EXCEEDED-ERROR error
      expect (Time.monotonic-us - started < 4_000_000)
    checked.get
    expect transport.closed
    expect (not pairing.encrypted and not pairing.authenticated and not link.encrypted)
    expect-equals 12 pairing.failure-reason
    pairing.close
    system.process-stats --gc
    expect-equals 12 pairing.failure-reason
  finally:
    if client: client.close
    responder.cancel
    peer.close
    host.close
    host.wait-closed

// The host transmits start fragments with PB=0. Convert to the inbound PB=2
// representation expected by the reassembler. Return credits per fragment.
take-smp transport/fixture.FakeTransport reassembler/acl.Reassembler --complete/bool=true -> ByteArray:
  while true:
    packet := transport.sent.take.copy
    expect-equals 2 packet[0]
    if packet[2] & 0x30 == 0: packet[2] |= 0x20
    result := reassembler.accept packet
    if complete: transport.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]
    if result:
      if result.channel == 4 and result.payload.size == 3 and result.payload[0] == 2:
        // The client exchanges its MTU before any security procedure; answer
        // it like a peer that accepts the client's value.
        transport.received.add (fixture.att-event (#[3] + result.payload[1..]))
        continue
      expect-equals 6 result.channel
      return result.payload

send-smp transport/fixture.FakeTransport packets/List:
  packets.do: | bytes/ByteArray |
    pdu := #[bytes.size, 0, 6, 0] + bytes
    offset := 0
    while offset < pdu.size:
      end := min (offset + 27) pdu.size
      transport.received.add (fixture.incoming-acl pdu[offset..end] --start=(offset == 0))
      offset = end

success --numeric/bool --random-address/bool=false --reject-at-encryption/bool=false --rejection-reason/int=12
    --rejection-packet/ByteArray?=null --complete-failure/bool=true:
  failure-packet := rejection-packet or #[5, rejection-reason]
  valid-failure := failure-packet.size == 2 and 1 <= failure-packet[1] <= 15
  local := random-address ? #[0xaa, 0xfb, 0x0d, 0x94, 0x81, 0x70] : #[6, 5, 4, 3, 2, 1]
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  peer := smp.Session --no-initiator --io-capability=(numeric ? 1 : 3)
      --require-authentication=numeric
      --local-address=#[1, 6, 5, 4, 3, 2, 1]
      --peer-address=(#[(random-address ? 1 : 0)] + (ByteArray 6: local[5 - it]))
  controller-ready := monitor.Latch
  allow-encryption := monitor.Latch
  done := monitor.Latch
  worker/Task? := null
  client/att.Client? := null
  responder := task::
    command := fixture.create-command.copy
    if random-address:
      fixture.reply transport (hci.command-packet 0x2005 local) #[]
      command[16] = 1
    fixture.status-reply transport command
    transport.received.add fixture.connection-event
    reassembler := acl.Reassembler 0x234 --limit=65
    while not peer.verified:
      send-smp transport (peer.receive (take-smp transport reassembler))
    expected := hci.command-packet 0x2019 (encryption.enable-parameters 0x234 peer.key)
    fixture.status-reply transport expected
    controller-ready.set true
    if reject-at-encryption:
      if not valid-failure:
        expect-equals #[5, 0x0a] (take-smp transport reassembler --complete=complete-failure)
        if not complete-failure:
          sleep --ms=20
          expect (not transport.closed)
    else:
      allow-encryption.get
      transport.received.add #[4, 8, 4, 0, 0x34, 2, 1]
      fixture.gatt-reply transport #[0x0a, 1, 0] #[0x0b, 42]
  try:
    link := host.connect #[1, 2, 3, 4, 5, 6] --address-type=1
        --local-random-address=(random-address ? local : null)
    if random-address:
      expect-equals local link.local-random-address
      snapshot := link.local-random-address
      snapshot[0] ^= 1
      expect-equals local link.local-random-address
      expect-throw "SMP_WRONG_LOCAL_ADDRESS":
        security.Pairing host link --local-address=local --io-capability=3 --no-require-authentication
      expect-throw "SMP_WRONG_LOCAL_ADDRESS":
        security.Pairing host link --local-address=snapshot --local-address-type=1
            --io-capability=3
            --no-require-authentication
    else:
      expect-throw "SMP_WRONG_LOCAL_ADDRESS":
        security.Pairing host link --local-address=local --local-address-type=1
            --io-capability=3
            --no-require-authentication
    [-1, 2].do: | invalid-type/int |
      expect-throw "INVALID_ARGUMENT":
        security.Pairing host link --local-address=local --local-address-type=invalid-type
            --io-capability=3
            --no-require-authentication
    pairing := security.Pairing host link --local-address=local
        --local-address-type=(random-address ? 1 : 0)
        --io-capability=(numeric ? 1 : 3)
        --require-authentication=numeric
    client = att.Client host link --pairing=pairing
    confirmations := 0
    worker = task::
      failure := catch: pairing.run: | number/int |
        confirmations++
        expect numeric
        expect-equals peer.comparison-number number
        // The scoped UI block may wait without stopping ATT reception.
        transport.received.add (fixture.att-event #[0x1b, 7, 0, 99])
        notification := client.receive-notification
        expect-equals 7 notification.handle
        expect-equals #[99] notification.value
        system.process-stats --gc
        expect-equals #[99] notification.value
        send-smp transport (peer.approve true)
        true
      if failure: done.set failure --exception
      else: done.set true
    controller-ready.get
    expect (not pairing.encrypted and not pairing.authenticated)
    sent := transport.sent-count
    [0, 4, 8, 0x0d, 0xff].do: | auth/int |
      pairing.receive #[0x0b, auth]
      expect-equals sent transport.sent-count
      expect (not pairing.encrypted and not pairing.authenticated)
    // Follow a Security Request with a notification on the same ATT receive
    // loop. Delivery proves the SMP request was handled without aborting it.
    send-smp transport [#[0x0b, 0x0d]]
    transport.received.add (fixture.att-event #[0x1b, 7, 0, 77])
    notification := client.receive-notification
    expect-equals #[77] notification.value
    expect-equals sent transport.sent-count
    expect (not pairing.encrypted and not pairing.authenticated)
    if reject-at-encryption:
      send-smp transport [failure-packet]
      error := catch: done.get
      if complete-failure:
        expect (error is PairingError)
        expect-equals (valid-failure ? failure-packet[1] : 0x0a) error.reason
      else:
        expect-equals DEADLINE-EXCEEDED-ERROR error
      expect (not pairing.encrypted and not pairing.authenticated and not link.connected)
      pairing.close
      system.process-stats --gc
      expect-equals (valid-failure ? failure-packet[1] : 0x0a) pairing.failure-reason
      return
    allow-encryption.set true
    done.get
    expect pairing.encrypted
    expect-equals null pairing.failure-reason
    expect-equals numeric pairing.authenticated
    expect-equals (numeric ? 1 : 0) confirmations
    expect-equals #[42] (client.read 1)
    expect-throw "SMP_INVALID_STATE": pairing.run: unreachable
    // run installs the lifetime guard automatically; encryption loss ends the
    // usable connection even when no ATT request is currently waiting.
    transport.received.add #[4, 8, 4, 0, 0x34, 2, 0]
    while link.connected: sleep --ms=1
    expect (not pairing.encrypted and not pairing.authenticated)
    client.close
  finally:
    if worker: worker.cancel
    if client: client.close
    responder.cancel
    peer.close
    host.close
    host.wait-closed

canceled --explicit/bool=false --mapped/bool=false:
  attempts := retry.Attempts --minimum=(Duration --s=10)
  irk := ByteArray 16: it
  first-address := mapped ? (privacy.from-prand irk #[0x41, 2, 3]) : #[1, 2, 3, 4, 5, 6]
  next-address := mapped ? (privacy.from-prand irk #[0x42, 2, 3]) : first-address
  stable/ByteArray? := null
  if mapped:
    expect (first-address != next-address)
    expect (privacy.resolves irk first-address 1)
    expect (privacy.resolves irk next-address 1)
    // Trusted caller maps both resolved RPAs to the same stable identity.
    stable = #[0, 9, 8, 7, 6, 5, 4]
  command := fixture.create-command.copy
  event := fixture.connection-event.copy
  6.repeat: | index/int |
    command[10 + index] = first-address[index]
    event[9 + index] = first-address[index]
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  client/att.Client? := null
  sent := monitor.Latch
  ended := monitor.Latch
  worker/Task? := null
  responder := task::
    fixture.status-reply transport command
    transport.received.add event
    take-smp transport (acl.Reassembler 0x234 --limit=65)
    sent.set true
  try:
    link := host.connect first-address --address-type=1
    pairing := security.Pairing host link --local-address=#[6, 5, 4, 3, 2, 1]
        --io-capability=3
        --no-require-authentication
        --attempts=attempts
        --attempt-identity=stable
    // Identity ownership must survive caller mutation before pairing starts.
    if stable: stable[1] = 0xff
    client = att.Client host link --pairing=pairing
    if explicit:
      worker = task::
        try:
          pairing.run: unreachable
        finally:
          critical-do --no-respect-deadline: ended.set true
      sent.get
      worker.cancel
      ended.get
    else:
      expect-throw DEADLINE-EXCEEDED-ERROR:
        with-timeout --ms=30: pairing.run: unreachable
    expect (not link.connected and not pairing.encrypted)
    expect-equals null pairing.failure-reason
  finally:
    if worker: worker.cancel
    if client: client.close
    responder.cancel
    host.close
    host.wait-closed
  blocked-pairing attempts
      --attempt-identity=(mapped ? #[0, 9, 8, 7, 6, 5, 4] : null)
      --peer-address=next-address

peripheral-success --random-address/bool=false --failure/int=0:
  local := random-address ? #[0xaa, 0xfb, 0x0d, 0x94, 0x81, 0x70] : #[6, 5, 4, 3, 2, 1]
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  peer := smp.Session --initiator --io-capability=3
      --no-require-authentication
      --local-address=#[1, 6, 5, 4, 3, 2, 1]
      --peer-address=(#[(random-address ? 1 : 0)] + (ByteArray 6: local[5 - it]))
  start := monitor.Latch
  key-replied := monitor.Latch
  allow-encryption := monitor.Latch
  done := monitor.Latch
  paired := monitor.Latch
  reads-done := monitor.Latch
  server/gatt-server.Server? := null
  workers := []
  responder := task::
    key-fixture.establish transport --local-random-address=(random-address ? local : null)
    start.get
    transport.received.add (fixture.att-event #[0x0a, 3, 0])
    fixture.att-sent transport #[1, 0x0a, 3, 0, 5]
    send-smp transport peer.start
    reassembler := acl.Reassembler 0x234 --limit=65
    while not peer.verified:
      send-smp transport (peer.receive (take-smp transport reassembler))
    // Ask immediately after receiving the final DHKey Check, before the
    // application's pairing task has necessarily resumed.
    transport.received.add key-fixture.request
    expected := hci.command-packet 0x201a (encryption.reply-parameters 0x234 peer.key)
    fixture.reply transport expected #[0x34, 2]
    transport.received.add (fixture.att-event #[0x0a, 3, 0])
    fixture.att-sent transport #[1, 0x0a, 3, 0, 0x0f]
    key-replied.set true
    allow-encryption.get
    transport.received.add #[4, 8, 4, (max failure 0), 0x34, 2, (failure == 0 ? 1 : 0)]
    if failure == 0:
      paired.get
      transport.received.add (fixture.att-event #[0x0a, 3, 0])
      fixture.att-sent transport #[0x0b, 42]
      transport.received.add (fixture.att-event #[0x0a, 5, 0])
      fixture.att-sent transport #[1, 0x0a, 5, 0, 5]
      reads-done.set true
  try:
    link := host.accept #[2, 1, 6] --local-random-address=(random-address ? local : null)
    if random-address:
      expect-equals local link.local-random-address
      snapshot := link.local-random-address
      snapshot[0] ^= 1
      expect-equals local link.local-random-address
      expect-throw "SMP_WRONG_LOCAL_ADDRESS":
        security.Pairing host link --local-address=local --io-capability=3 --no-require-authentication
      expect-throw "SMP_WRONG_LOCAL_ADDRESS":
        security.Pairing host link --local-address=snapshot --local-address-type=1
            --io-capability=3
            --no-require-authentication
    else:
      expect-throw "SMP_WRONG_LOCAL_ADDRESS":
        security.Pairing host link --local-address=local --local-address-type=1
            --io-capability=3
            --no-require-authentication
    [-1, 2].do: | invalid-type/int |
      expect-throw "INVALID_ARGUMENT":
        security.Pairing host link --local-address=local --local-address-type=invalid-type
            --io-capability=3
            --no-require-authentication
    pairing := security.Pairing host link --local-address=local
        --local-address-type=(random-address ? 1 : 0)
        --io-capability=3
        --no-require-authentication
    database := attributes.Database
    database.add-service #[0xf0, 0xff]
    database.add-characteristic #[0xf1, 0xff] --read --encrypted --value=#[42]
    database.add-characteristic #[0xf2, 0xff] --read --authenticated --value=#[43]
    server = gatt-server.Server host link database --pairing=pairing
    workers.add (task::
      error := catch: server.serve: unreachable
      if failure == 0 and error: throw error)
    workers.add (task::
      // Start is released by a separate task after run has entered its wait.
      error := catch: pairing.run: unreachable
      done.set error)
    workers.add (task::
      sleep --ms=1
      start.set true)
    key-replied.get
    expect (not pairing.encrypted)
    allow-encryption.set true
    error := done.get
    if failure != 0:
      if failure > 0:
        expect (error is encryption.Error)
        expect-equals failure error.status
      else:
        expect-equals "HCI_ENCRYPTION_NOT_ENABLED" error
      expect (not pairing.encrypted and not pairing.authenticated and not link.connected)
      return
    expect-null error
    expect (pairing.encrypted and not pairing.authenticated)
    paired.set true
    reads-done.get
    server.close
    expect (not pairing.encrypted)
  finally:
    workers.do: it.cancel
    if server: server.close
    responder.cancel
    peer.close
    host.close
    host.wait-closed

// A fresh controller/link/owner must not bypass shared failed-pairing history.
blocked-pairing attempts/retry.Attempts --attempt-identity/ByteArray?=null --peer-address/ByteArray?=null:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport)
  client/att.Client? := null
  address := peer-address or #[1, 2, 3, 4, 5, 6]
  command := fixture.create-command.copy
  event := fixture.connection-event.copy
  6.repeat: | index/int |
    command[10 + index] = address[index]
    event[9 + index] = address[index]
  connected := monitor.Latch
  responder := task::
    fixture.status-reply transport command
    transport.received.add event
    connected.set true
  try:
    link := host.connect address --address-type=1
    connected.get
    pairing := security.Pairing host link --local-address=#[6, 5, 4, 3, 2, 1]
        --io-capability=1
        --require-authentication
        --attempts=attempts
        --attempt-identity=attempt-identity
    client = att.Client host link --pairing=pairing
    sent-before := transport.sent-count
    expect-throw "SMP_REPEATED_ATTEMPTS": pairing.run: unreachable
    expect-equals null pairing.failure-reason
    expect-equals sent-before transport.sent-count
    expect transport.closed
    expect (not pairing.encrypted and not pairing.authenticated and not link.encrypted)
  finally:
    if client: client.close
    responder.cancel
    host.close
    host.wait-closed
