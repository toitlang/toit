// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Linux central for tests/ble-hardware/legacy-bond.sh: pairs with a legacy
// (no Secure Connections) peripheral advertising service fff0, stores the
// bond as a sealed record, and on the next run resumes it with the peer's
// distributed key instead of pairing again.

import ble.experimental.advertising
import ble.experimental.att
import ble.experimental.bond
import ble.experimental.bond-protection
import ble.experimental.bond-resume
import ble.experimental.central
import ble.experimental.gatt
import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.scanning
import ble.experimental.security
import ble.experimental.security-owner show Owner
import encoding.hex
import host.file

SERVICE ::= #[0xf0, 0xff]
CHARACTERISTIC ::= #[0xf1, 0xff]

main args/List:
  if args.size != 3: throw "Usage: legacy-bond-central.toit <adapter index> <pair|resume> <record path>"
  mode/string := args[1]
  path/string := args[2]
  if mode != "pair" and mode != "resume": throw "INVALID_MODE"
  if mode == "pair" and (file.is-file path): throw "RECORD_ALREADY_EXISTS"
  // Public fixture storage key; not production provisioning.
  protection := bond-protection.Protection (ByteArray 32: it)
  context := "toit.test/legacy-bond".to-byte-array
  saved/bond.Candidate? := null
  if mode == "resume":
    saved = protection.open (file.read-contents path) --context=context
    if not saved.legacy or not saved.peer-legacy: throw "RECORD_NOT_A_LEGACY_BOND"
  controller/hci.Controller? := null
  host/central.Central? := null
  client/att.Client? := null
  owner/Owner? := null
  try:
    controller = hci.Controller (linux.LinuxTransport (int.parse args[0]))
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    peer/advertising.Report? := null
    with-timeout --ms=20_000:
      scanning.scan controller --active: | report/advertising.Report |
        if not (report.has-service SERVICE): continue.scan true
        peer = report
        false
    print "LEGACY_BOND peer=$(hex.encode peer.address.reverse) type=$(peer.address-type) mode=$mode"
    if saved and not (saved.peer.matches peer.address --address-type=peer.address-type):
      throw "RECORD_FOR_ANOTHER_PEER"
    link := host.connect peer.address --address-type=peer.address-type
    owner = saved
        ? (bond-resume.Resume host link saved --local-address=info.address)
        : (security.Pairing host link --local-address=info.address --io-capability=3
            --no-require-authentication
            --bond)
    client = att.Client host link --pairing=owner
    if saved:
      (owner as bond-resume.Resume).run
    else:
      (owner as security.Pairing).run (: unreachable) --candidate=: | candidate/bond.Candidate |
        if not candidate.legacy: throw "PEER_PAIRED_WITH_SECURE_CONNECTIONS"
        if not candidate.peer-legacy: throw "PEER_DISTRIBUTED_NO_KEY"
        sealed := protection.seal candidate --context=context
        file.write-contents sealed --path=path --permissions=0x180
        print "LEGACY_BOND candidate-saved=true local-key=$(candidate.local-legacy != null) ediv=$(candidate.peer-legacy.ediv)"
    if not owner.encrypted or owner.authenticated: throw "WRONG_SECURITY_STATE"
    services := (gatt.services client).filter: it.uuid == SERVICE
    if services.size != 1: throw "SERVICE_NOT_FOUND"
    characteristics := (gatt.characteristics client services[0]).filter: it.uuid == CHARACTERISTIC
    if characteristics.size != 1: throw "CHARACTERISTIC_NOT_FOUND"
    value := gatt.read client characteristics[0]
    if value != #[42]: throw "WRONG_ENCRYPTED_VALUE $value"
    host.disconnect link
    print "LEGACY_BOND COMPLETE resumed=$(saved != null) encrypted-read=true"
  finally:
    if client: client.close
    if owner: owner.close
    if host:
      host.close
      host.wait-closed
    if controller:
      controller.close
      controller.wait-closed
    protection.close
