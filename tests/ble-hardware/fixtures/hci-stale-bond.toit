// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.advertising
import ble.experimental.bond
import ble.experimental.bond-resume
import ble.experimental.central
import ble.experimental.encryption
import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.scanning
import ble.experimental.smp-identity
import encoding.hex
import system
import uuid

// Uses only public fixture material. Never reads or changes the BlueZ bond.
main args/List:
  if args.size != 1: throw "Usage: hci-stale-bond.toit <adapter index>"
  controller := hci.Controller (linux.LinuxTransport (int.parse args[0]))
  host/central.Central? := null
  owner/bond-resume.Resume? := null
  try:
    info := hci.initialize controller
    if info.address != #[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8]: throw "WRONG_FIXTURE_ADAPTER"
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    service := (uuid.Uuid.parse "9f6c4000-8e2a-4b13-9e97-94f353eeb001").to-byte-array.reverse
    peer/advertising.Report? := null
    with-timeout --ms=10_000:
      scanning.scan controller --active: | report/advertising.Report |
        if not (report.has-service service): continue.scan true
        peer = report
        false
    local := smp-identity.Identity (ByteArray 16) info.address 0
    identity := smp-identity.Identity (hex.decode "ec0234a357c8ad05341010a60a397d9b")
        #[0xaa, 0x4d, 0x23, 0xf2, 0x3a, 8]
        0
    // Deliberately stale public key; the peer holds its independently derived LTK.
    candidate := bond.Candidate (ByteArray 16: it) local identity --authenticated=false
    link := host.connect peer.address --address-type=peer.address-type
    print "BLE_STALE_BOND connected=true peer=$(hex.encode peer.address.reverse)"
    owner = bond-resume.Resume host link candidate --local-address=info.address
    if owner.paired or owner.encrypted or owner.authenticated: throw "PREMATURE_SECURITY_GRANT"
    error := catch: owner.run --timeout=(Duration --s=15)
    print "BLE_STALE_BOND error=$error"
    if not error: throw "STALE_KEY_ACCEPTED"
    reason := with-timeout --ms=5_000: link.wait-disconnected
    print "BLE_STALE_BOND disconnected=true reason=$reason"
    system.process-stats --gc
    if owner.paired or owner.encrypted or owner.authenticated or link.connected:
      throw "SECURITY_GRANT_AFTER_FAILURE"
    print "BLE_STALE_BOND security-granted=false connected=false"
    // A timeout or arbitrary transport failure is not proof of key rejection.
    rejected := error is encryption.Error and (error.status == 5 or error.status == 6 or error.status == 0x3d)
    rejected = rejected or (error == "HCI_LINK_DISCONNECTED" and (reason == 5 or reason == 6 or reason == 0x3d))
    if not rejected: throw "NO_CONTROLLER_KEY_REJECTION"
    print "BLE_STALE_BOND COMPLETE rejected=true reason=$reason encrypted=false"
  finally:
    if owner: owner.close
    if host:
      host.close
      host.wait-closed
    controller.close
    controller.wait-closed
