// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-flash
import ble.experimental.bond-table
import ble.experimental.bond-revocation
import ble.experimental.bond-registry
import ble.experimental.bond-resume
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.privacy
import ble.experimental.security
import ble.experimental.security-owner show Owner
import ble.experimental.smp-identity
import ble.experimental.transport
import ble.experimental.service.gatt-provider as service
import encoding.hex
import .vhci-pairing show PairingTrace

main:
  // Public fixture storage key; no application container receives this store.
  // Separate from the older opaque-slot fixture; no implicit bond migration.
  records := bond-revocation.RevocableRecords (bond-flash.FlashRecords "toit.test/ble-service-table")
  store := bond-table.Table records (ByteArray 32: it)
      --capacity=1
  registry := bond-registry.Registry store
  provider := Provider store registry
  try:
    provider.install
    with-timeout --ms=120_000: provider.uninstall --wait
    if not provider.secured: throw "SERVICE_SECURITY_NOT_COMPLETED"
    if provider.resumed:
      registry.remove 0
      if not store.occupied.is-empty: throw "BOND_SERVICE_DELETE_NOT_VERIFIED"
      print "BOND_SERVICE candidate-deleted=true"
    print "BOND_SERVICE COMPLETE resumed=$(provider.resumed)"
  finally:
    provider.uninstall
    registry.close

class Provider extends service.Provider:
  store_/bond-table.Table
  registry_/bond-registry.Registry
  host_/Host? := null
  resumed/bool := false
  secured/bool := false

  constructor .store_ .registry_:
    super

  open-transport -> transport.Transport: return PairingTrace (esp32.Esp32Transport)

  create-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    saved := store_.load 0
    resumed = saved != null
    host_ = Host controller info receive-limit saved registry_
    print "BOND_SERVICE READY mode=$(resumed ? "resume" : "pair")"
    return host_

  local-random-address -> ByteArray?:
    saved := host_.saved
    if not saved: return null
    if not saved.local.has-resolving-key: throw "MISSING_LOCAL_IRK"
    address := privacy.generate saved.local.irk
    print "BOND_SERVICE RPA address=$(hex.encode address.reverse)"
    return address

  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    prepared := host as Host
    if prepared.saved: return prepared.owner
    identity := smp-identity.Identity (hex.decode "ec0234a357c8ad05341010a60a397d9b") info.address 0
    return security.Pairing host link --local-address=info.address --io-capability=3
        --attempts=pairing-attempts
        --attempt-identity=(pairing-peer-identity link)
        --no-require-authentication
        --bond
        --identity=identity

  run-security-owner owner/Owner -> none:
    if resumed:
      (owner as bond-resume.Resume).run
    else:
      (owner as security.Pairing).run (: unreachable) --candidate=: | candidate/bond.Candidate |
        if candidate.peer.address-type != 0 or candidate.peer.address != #[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8]:
          throw "UNEXPECTED_REFERENCE_IDENTITY"
        // Insertion refuses an occupied slot; re-pairing never replaces a bond.
        registry_.add candidate
        print "BOND_SERVICE candidate-saved=true"
    secured = true
    print "BOND_SERVICE ENCRYPTED resumed=$resumed authenticated=$(owner.authenticated)"

class Host extends central.Central:
  saved/bond.Candidate?
  local_/ByteArray
  owner/bond-resume.Resume? := null
  registry_/bond-registry.Registry

  constructor controller/hci.Controller info/hci.Capabilities receive-limit/int .saved .registry_:
    local_ = info.address.copy
    super controller --acl-length=info.acl-length --acl-count=info.acl-count --receive-limit=receive-limit

  on-connected link/central.Link -> none:
    if saved:
      owner = registry_.resume this link --local-address=(link.local-random-address or local_)
