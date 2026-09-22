// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-registry
import ble.experimental.bond-resume
import ble.experimental.bond-storage
import ble.experimental.bond-table
import ble.experimental.central
import ble.experimental.security
import ble.experimental.security-owner show Owner
import ble.experimental.smp-identity as identity
import crypto
import encoding.hex
import system

S3 ::= #[0xfe, 0x50, 0xc1, 0xfa, 0x12, 0xf4]
PEER ::= #[0xae, 0xe0, 0x60, 0xac, 0xcd, 0x98]
LINUX ::= #[0xa9, 0x56, 0xa3, 0x4b, 0x88, 0x8a]

// Test-only storage key and approval policy. Never prints candidate/key data.
class State:
  table/bond-table.Table
  registry/bond-registry.Registry
  peers/List
  resume-only/bool
  label/string
  fresh/int := 0
  resumed/int := 0
  confirmed/int := 0
  local_/ByteArray? := null
  original_/List ::= []
  owners_/List ::= []
  exchange-identities/bool
  identity_/identity.Identity? := null

  constructor records/bond-storage.Records .peers .label --.resume-only/bool
      --.exchange-identities/bool=false:
    table = bond-table.Table records (ByteArray 32: it) --capacity=peers.size
    occupied := table.occupied
    if occupied.size != (resume-only ? peers.size : 0): throw "MIXED_RESUME_WRONG_STORAGE_PHASE"
    if resume-only:
      peers.size.repeat: original_.add (table.load it).encode
      if exchange-identities:
        peers.size.repeat:
          candidate := table.load it
          if not candidate.local.has-resolving-key or not candidate.peer.has-resolving-key:
            throw "MIXED_RESUME_IRK_MISSING"
          if identity_ and (identity_.irk != candidate.local.irk or identity_.address != candidate.local.address):
            throw "MIXED_RESUME_LOCAL_IDENTITY_CHANGED"
          identity_ = candidate.local
    registry = bond-registry.Registry table --owner-limit=peers.size

  owner host/central.Central link/central.Link local/ByteArray -> Owner:
    if local_ and local_ != local: throw "MIXED_RESUME_LOCAL_CHANGED"
    local_ = local.copy
    if exchange-identities and not identity_:
      identity_ = identity.Identity (crypto.random --size=16) local 0
    selected/Owner? := null
    known := registry.resolve-peer-identity --local-address=local --local-address-type=0
        --peer-address=link.info.address
        --peer-address-type=link.info.address-type
    if known:
      if known[0] != 0 or not (peers.contains known[1..]): throw "MIXED_RESUME_UNEXPECTED_IDENTITY"
      selected = registry.resume host link --local-address=local --require-authentication
      if link.info.address-type == 1:
        if not exchange-identities: throw "MIXED_RESUME_UNEXPECTED_PRIVATE"
        print "MIXED_RESUME $label PRIVATE peer=$(hex.encode link.info.address.reverse) identity=$(hex.encode known[1..].reverse) resolved=true"
    else:
      if resume-only: throw "MIXED_RESUME_BOND_MISSING"
      if link.info.address-type != 0 or not (peers.contains link.info.address):
        throw "MIXED_RESUME_UNEXPECTED_PEER"
      selected = security.Pairing host link --local-address=local
          --io-capability=1
          --require-authentication
          --bond
          --identity=identity_
          --request-identity=exchange-identities
    owners_.add selected
    system.process-stats --gc
    return selected

  secure selected/Owner role/int:
    if selected is bond-resume.Resume:
      (selected as bond-resume.Resume).run
      resumed++
      print "MIXED_RESUME $label RESUMED role=$role authenticated=$(selected.authenticated)"
    else:
      if resume-only: throw "MIXED_RESUME_PAIRING_FORBIDDEN"
      (selected as security.Pairing).run
          (: | number/int |
            confirmed++
            print "MIXED_RESUME $label NUMERIC role=$role value=$number fixture-approval=true"
            true)
          --candidate=: | candidate/bond.Candidate |
            index := peers.index-of candidate.peer.address
            if index < 0 or candidate.peer.address-type != 0 or not candidate.authenticated or
                candidate.local.address != local_ or candidate.local.address-type != 0:
              throw "MIXED_RESUME_BAD_CANDIDATE"
            if exchange-identities:
              if not candidate.local.has-resolving-key or not candidate.peer.has-resolving-key or
                  candidate.local.irk != identity_.irk:
                throw "MIXED_RESUME_BAD_IDENTITY"
            slot := registry.add candidate
            if slot != index: throw "MIXED_RESUME_BAD_SLOT"
            print "MIXED_RESUME $label SAVED slot=$slot authenticated=true"
      fresh++
    if not selected.encrypted or not selected.authenticated: throw "MIXED_RESUME_SECURITY"

  check expected-fresh/int expected-resumed/int:
    if fresh != expected-fresh or confirmed != expected-fresh or resumed != expected-resumed:
      throw "MIXED_RESUME_COUNTS"
    owners_.do: if (it as Owner).encrypted: throw "MIXED_RESUME_OWNER_STILL_LIVE"
    if table.occupied.size != peers.size: throw "MIXED_RESUME_RECORDS_MISSING"
    if resume-only:
      peers.size.repeat:
        if (table.load it).encode != original_[it]: throw "MIXED_RESUME_RECORD_CHANGED"
    print "MIXED_RESUME $label COMPLETE fresh=$fresh resumed=$resumed stored=$(peers.size) unchanged=$resume-only"

  close: registry.close
