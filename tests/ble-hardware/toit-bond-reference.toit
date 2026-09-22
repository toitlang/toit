// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.advertising
import ble.experimental.att
import ble.experimental.bond
import ble.experimental.bond-protection
import ble.experimental.bond-resume
import ble.experimental.central
import ble.experimental.encryption
import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.scanning
import ble.experimental.security
import ble.experimental.security-owner show Owner
import encoding.hex
import host.file
import system
import uuid

main args/List:
  if not 3 <= args.size <= 4: throw "Usage: toit-bond-reference.toit <adapter index> <pair|stale|resume> <record path> [service UUID]"
  mode/string := args[1]
  path/string := args[2]
  if mode != "pair" and mode != "resume" and mode != "stale": throw "INVALID_MODE"
  if mode == "pair" and (file.is-file path): throw "FIXTURE_RECORD_ALREADY_EXISTS"
  // Public fixture storage key. Restrict the directory and record permissions;
  // this is not production provisioning or power-cut-safe file storage.
  protection := bond-protection.Protection (ByteArray 32: it)
  context := "toit.test/linux-reconnect".to-byte-array
  saved/bond.Candidate? := null
  record/ByteArray? := null
  controller/hci.Controller? := null
  host/central.Central? := null
  client/att.Client? := null
  owner/Owner? := null
  try:
    if mode != "pair":
      record = file.read-contents path
      saved = protection.open record --context=context
      if mode == "stale":
        changed-key := saved.key
        changed-key[0] ^= 1
        saved = bond.Candidate changed-key saved.local saved.peer --authenticated=saved.authenticated
    controller = hci.Controller (linux.LinuxTransport (int.parse args[0]))
    info := hci.initialize controller
    if info.address != #[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8]: throw "WRONG_FIXTURE_ADAPTER"
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    service-id := args.size == 4 ? args[3] : "9f6c4100-8e2a-4b13-9e97-94f353eeb001"
    service := (uuid.Uuid.parse service-id).to-byte-array.reverse
    peer/advertising.Report? := null
    with-timeout --ms=10_000:
      scanning.scan controller --active: | report/advertising.Report |
        if not (report.has-service service): continue.scan true
        peer = report
        false
    if saved and peer.address-type != 1: throw "EXPECTED_PRIVATE_ADVERTISER"
    print "TOIT_BOND peer=$(hex.encode peer.address.reverse) type=$(peer.address-type) mode=$mode"
    link := host.connect peer.address --address-type=peer.address-type
    owner = saved
        ? (bond-resume.Resume host link saved --local-address=info.address)
        : (security.Pairing host link --local-address=info.address --io-capability=3
            --no-require-authentication
            --bond
            --request-identity)
    client = att.Client host link --pairing=owner
    if mode == "stale":
      error := catch: (owner as bond-resume.Resume).run --timeout=(Duration --s=15)
      if not error: throw "CHANGED_KEY_ACCEPTED"
      reason := with-timeout --ms=5_000: link.wait-disconnected
      explicit := error is encryption.Error and (error.status == 5 or error.status == 6 or error.status == 0x3d)
      disconnected := error == "HCI_LINK_DISCONNECTED" and (reason == 5 or reason == 6 or reason == 8 or reason == 0x3d)
      explicit = explicit or (disconnected and reason != 8)
      if not explicit and not disconnected: throw error
      read-error := catch: with-timeout --ms=2_000: client.read 12
      if not read-error or read-error == DEADLINE-EXCEEDED-ERROR: throw "PROTECTED_ACCESS_NOT_REJECTED"
      system.process-stats --gc
      if owner.paired or owner.encrypted or owner.authenticated or link.connected:
        throw "SECURITY_GRANT_AFTER_CHANGED_KEY"
      if (file.read-contents path) != record: throw "ORIGINAL_RECORD_CHANGED"
      print "TOIT_BOND STALE access-denied=true reason=$reason controller-key-rejection=$explicit original-record-unchanged=true"
      // A supervision timeout is recorded as such, not as explicit key rejection.
      // The final correct-key phase is required to establish recovery.
      return
    if saved:
      (owner as bond-resume.Resume).run
    else:
      (owner as security.Pairing).run (: unreachable) --candidate=: | candidate/bond.Candidate |
        if candidate.peer.address != #[0xaa, 0x4d, 0x23, 0xf2, 0x3a, 8] or not candidate.peer.has-resolving-key:
          throw "WRONG_FIXTURE_IDENTITY"
        sealed := protection.seal candidate --context=context
        file.write-contents sealed --path=path --permissions=0x180
        if (file.read-contents path) != sealed: throw "FIXTURE_RECORD_WRITE_FAILED"
        print "TOIT_BOND candidate-saved=true"
    if not owner.encrypted or owner.authenticated: throw "WRONG_SECURITY_STATE"
    value := client.read 12
    if value != #[42]: throw "WRONG_ENCRYPTED_VALUE"
    error := catch: client.read 14
    if not (error is att.AttributeError and error.code == 5): throw "WRONG_AUTHENTICATION_RESULT"
    system.process-stats --gc
    if value != #[42] or (client.read 12) != #[42]: throw "ENCRYPTED_READ_AFTER_GC_FAILED"
    host.disconnect link
    if saved: file.delete path
    print "TOIT_BOND COMPLETE resumed=$(saved != null) encrypted-reads=2 authentication-error=5"
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
