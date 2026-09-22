// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt-server
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.smp-identity as identity
import ble.experimental.smp-features show PairingError
import encoding.hex
import ble.experimental.transport show Transport
import monitor
import system
import .hci-echo as fixture

main:
  run

run --numeric/bool=false --local-random-address/ByteArray?=null --exchange-identity/bool=false
    --expect-rejection/bool=false --reject-numeric/bool=false --value-base/int=42 --delay-third-read/bool=false:
  if (expect-rejection or reject-numeric) and not numeric: throw "INVALID_ARGUMENT"
  if not 0 <= value-base <= 254: throw "INVALID_ARGUMENT"
  controller := hci.Controller (PairingTrace (esp32.Esp32Transport))
  host/central.Central? := null
  server/gatt-server.Server? := null
  worker/Task? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    database := attributes.Database.with-defaults --name="Toit SC"
    uuid := fixture.wire-uuid "9f6c4000-8e2a-4b13-9e97-94f353eeb001"
    database.add-service uuid
    encrypted-handle := database.add-characteristic (fixture.wire-uuid "9f6c4001-8e2a-4b13-9e97-94f353eeb001")
        --read
        --encrypted
        --notify=delay-third-read
        --dynamic-read=delay-third-read
        --value=#[value-base]
    database.add-characteristic (fixture.wire-uuid "9f6c4002-8e2a-4b13-9e97-94f353eeb001")
        --read
        --authenticated
        --value=#[value-base + 1]
    advertisement := #[2, 1, 6, 17, 7] + uuid
    mode := numeric ? "numeric-comparison" : "just-works"
    print "VHCI_PAIRING READY mode=$mode"
    link := host.accept advertisement --timeout=(Duration --s=60)
        --local-random-address=local-random-address
    local-identity := exchange-identity
        ? (identity.Identity (hex.decode "ec0234a357c8ad05341010a60a397d9b") info.address 0)
        : null
    pairing := security.Pairing host link --local-address=(link.local-random-address or info.address)
        --local-address-type=(link.local-random-address ? 1 : 0)
        --io-capability=(numeric ? 1 : 3)
        --require-authentication=numeric
        --identity=local-identity
        --request-identity=exchange-identity
    server = gatt-server.Server host link database --pairing=pairing
    finished := monitor.Latch
    worker = task::
      reads := 0
      error := catch:
        if delay-third-read:
          server.serve-with-requests
              (: | request/attributes.ReadRequest |
                if request.handle != encrypted-handle: throw "UNEXPECTED_DYNAMIC_READ"
                reads++
                if reads == 3:
                  if not (server.notify encrypted-handle): throw "DELAY_PEER_NOT_SUBSCRIBED"
                  print "VHCI_PAIRING READ_PENDING value=$value-base"
                  sleep --ms=750
                request.reply #[value-base])
              (: | request/attributes.WriteRequest | unreachable)
              (: | handle/int value/ByteArray |
                if handle != encrypted-handle + 1 or (value != #[1, 0] and value != #[0, 0]):
                  throw "UNEXPECTED_FIXTURE_WRITE")
        else:
          server.serve: unreachable
      finished.set error
    pairing-error := catch: with-timeout --ms=45_000:
      pairing.run: | number/int |
        if not numeric: throw "UNEXPECTED_NUMERIC_COMPARISON"
        // Test-only approval: the independent BlueZ agent reads this fresh
        // serial record and rejects unless its own number matches exactly.
        // A product must obtain explicit approval through its actual UI.
        print "VHCI_PAIRING NUMERIC value=$number fixture-approval=$(not reject-numeric)"
        not reject-numeric
    if expect-rejection or reject-numeric:
      if not (pairing-error is PairingError) or pairing-error.reason != 0x0c:
        throw "EXPECTED_PEER_NUMERIC_REJECTION"
      if pairing.encrypted or pairing.authenticated or link.encrypted: throw "REJECTED_PAIRING_ENCRYPTED"
      print "VHCI_PAIRING REJECTED reason=12 encrypted=false"
      return
    if pairing-error: throw pairing-error
    system.process-stats --gc
    if exchange-identity:
      peer := pairing.peer-identity
      if not peer: throw "PEER_IDENTITY_NOT_NEGOTIATED"
      if peer.address-type != 0 or peer.address != #[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8]:
        throw "UNEXPECTED_PEER_IDENTITY"
      print "VHCI_PAIRING IDENTITY received=true peer-matched=true has-irk=$(peer.has-resolving-key)"
    print "VHCI_PAIRING ENCRYPTED encrypted=$(pairing.encrypted) authenticated=$(pairing.authenticated)"
    error := with-timeout --ms=50_000: finished.get
    if error: throw error
    print "VHCI_PAIRING COMPLETE disconnected=true"
  finally:
    if worker: worker.cancel
    if server: server.close
    if host:
      host.close
      host.wait-closed
    controller.close
    controller.wait-closed

/** Fixture-only protocol metadata; never prints or retains cryptographic payloads. */
class PairingTrace implements Transport:
  underlying_/Transport
  count_/int := 0

  constructor .underlying_:

  receive -> ByteArray:
    packet := underlying_.receive
    record_ "RX" packet
    return packet

  send packet/ByteArray -> none:
    underlying_.send packet
    record_ "TX" packet

  send-if packet/ByteArray [allowed] -> bool:
    sent := underlying_.send-if packet allowed
    if sent: record_ "TX" packet
    return sent

  close -> none: underlying_.close

  record_ direction/string packet/ByteArray -> none:
    if count_ >= 100 or packet.size < 10 or packet[0] != 2: return
    // Continuations have no L2CAP header and may contain secret bytes.
    if packet[2] & 0x30 != 0 and packet[2] & 0x30 != 0x20: return
    if packet[8] != 0: return
    channel := packet[7]
    if channel == 6:
      count_++
      opcode := packet[9]
      print "PAIRING_META $direction smp-opcode=$opcode"
      if (opcode == 1 or opcode == 2) and packet.size == 16:
        print "PAIRING_META $direction auth=$(packet[12]) initiator-keys=$(packet[14]) responder-keys=$(packet[15])"
      if opcode == 5 and packet.size == 11:
        print "PAIRING_META $direction smp-failure=$(packet[10])"
    else if channel == 4 and packet[9] == 1 and packet.size == 14:
      count_++
      print "PAIRING_META $direction att-error request=$(packet[10]) code=$(packet[13])"
