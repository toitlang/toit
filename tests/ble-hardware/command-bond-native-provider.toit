// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-flash
import ble.experimental.bond-registry
import ble.experimental.bond-resume
import ble.experimental.bond-table
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.security-owner show Owner
import .command-native-overload-provider as fixture

NAMESPACE ::= "toit.test/command-bond-native-v1"
REFERENCE ::= #[0xa9, 0x56, 0xa3, 0x4b, 0x88, 0x8a]

run --expected-resume/bool --delete-after/bool=false:
  table := bond-table.Table (bond-flash.FlashRecords NAMESPACE) (ByteArray 32: it)
      --capacity=1
  registry := bond-registry.Registry table
  provider := Provider table registry --expected-resume=expected-resume
  try:
    provider.install
    provider.uninstall --wait
    if provider.sessions != 2 or provider.secured != 2:
      throw "COMMAND_BOND_INCOMPLETE"
    if delete-after:
      registry.remove 0
      if not table.occupied.is-empty: throw "COMMAND_BOND_DELETE_NOT_VERIFIED"
      print "COMMAND_BOND_PROVIDER candidate-deleted=true"
    print "COMMAND_OVERLOAD_PROVIDER COMPLETE"
  finally:
    provider.uninstall
    registry.close

class Provider extends fixture.Provider:
  table_/bond-table.Table
  registry_/bond-registry.Registry
  expected-resume_/bool
  selected-resume_/bool := false
  sessions/int := 0
  secured/int := 0

  constructor .table_ .registry_ --expected-resume/bool:
    expected-resume_ = expected-resume
    super --authenticated

  create-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    saved := table_.load 0
    selected-resume_ = saved != null
    if sessions == 0 and selected-resume_ != expected-resume_:
      throw "COMMAND_BOND_WRONG_INITIAL_PHASE"
    if sessions != 0 and not selected-resume_:
      throw "COMMAND_BOND_MISSING_RECOVERY_RECORD"
    sessions++
    print "COMMAND_BOND_PROVIDER READY mode=$(selected-resume_ ? "resume" : "pair") session=$sessions"
    return Host controller info receive-limit saved registry_

  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    prepared := host as Host
    if prepared.saved: return prepared.owner
    return security.Pairing host link
        --local-address=info.address
        --io-capability=1
        --require-authentication
        --attempts=pairing-attempts
        --attempt-identity=(pairing-peer-identity link)
        --bond

  run-security-owner owner/Owner -> none:
    if selected-resume_:
      (owner as bond-resume.Resume).run
    else:
      (owner as security.Pairing).run
          (: | number/int | confirm-pairing number)
          --candidate=: | candidate/bond.Candidate |
            if not candidate.authenticated or candidate.peer.address-type != 0 or
                candidate.peer.address != REFERENCE:
              throw "COMMAND_BOND_BAD_CANDIDATE"
            if (registry_.add candidate) != 0: throw "COMMAND_BOND_WRONG_SLOT"
            print "COMMAND_BOND_PROVIDER candidate-saved=true"
    if not owner.encrypted or not owner.authenticated:
      throw "COMMAND_BOND_SECURITY_REQUIRED"
    secured++
    print "COMMAND_OVERLOAD_PROVIDER AUTHENTICATED encrypted=true authenticated=true"
    print "COMMAND_BOND_PROVIDER ENCRYPTED resumed=$selected-resume_ session=$sessions"

class Host extends central.Central:
  saved/bond.Candidate?
  local_/ByteArray
  owner/bond-resume.Resume? := null
  registry_/bond-registry.Registry

  constructor controller/hci.Controller info/hci.Capabilities receive-limit/int .saved .registry_:
    local_ = info.address.copy
    super controller --acl-length=info.acl-length --acl-count=info.acl-count
        --receive-limit=receive-limit

  on-connected link/central.Link -> none:
    if saved:
      owner = registry_.resume this link
          --local-address=(link.local-random-address or local_)
          --require-authentication
