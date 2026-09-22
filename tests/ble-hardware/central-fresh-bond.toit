// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-flash
import ble.experimental.bond-storage
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.security-owner show Owner
import monitor
import .fixtures.vhci-central-provider as base
import .fixtures.vhci-central-bond-provider as diagnostics

IDENTITY ::= #[0x51, 0x31, 0x23, 0xf2, 0x3a, 0xc8]
PEER ::= #[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8]

// Isolated fixture identity and encrypted namespace; no access to the older
// central-service comparison record. The key is public test configuration.
run --resume/bool:
  store := bond-storage.Storage (bond-flash.FlashRecords "toit.test/central-fresh-001") (ByteArray 32: it)
  try:
    provider := Provider store resume
    with-timeout --ms=60_000: base.run provider
    if not provider.secured: throw "CENTRAL_FRESH_SECURITY_INCOMPLETE"
    print "CENTRAL_FRESH COMPLETE resumed=$resume candidate-retained=true"
  finally:
    store.close

class Provider extends base.Provider:
  store_/bond-storage.Storage
  resume_/bool
  candidate_/bond.Candidate? := null
  link_/central.Link? := null
  secured/bool := false

  constructor .store_ .resume_: super

  central-local-random-address info/hci.Capabilities -> ByteArray?: return IDENTITY.copy

  create-central-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    candidate_ = store_.load #[1]
    if resume_ and not candidate_: throw "CENTRAL_FRESH_MISSING_BOND"
    if not resume_ and candidate_: throw "CENTRAL_FRESH_BOND_ALREADY_EXISTS"
    print "CENTRAL_FRESH READY mode=$(resume_ ? "resume" : "pair")"
    return super controller info receive-limit

  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    link_ = link
    if resume_:
      return diagnostics.RequestTraceResume host link candidate_ --local-address=IDENTITY
    return security.Pairing host link --local-address=IDENTITY --local-address-type=1
        --attempts=pairing-attempts
        --attempt-identity=(pairing-peer-identity link)
        --io-capability=3
        --no-require-authentication
        --bond

  run-central-security-owner owner/Owner -> none:
    failure := catch:
      if resume_:
        (owner as diagnostics.RequestTraceResume).run
      else:
        (owner as security.Pairing).run (: unreachable) --candidate=: | candidate/bond.Candidate |
          if candidate.local.address-type != 1 or candidate.local.address != IDENTITY or
              candidate.peer.address-type != 0 or candidate.peer.address != PEER:
            throw "CENTRAL_FRESH_WRONG_IDENTITY"
          store_.save #[1] candidate
          print "CENTRAL_FRESH candidate-saved=true"
      if not owner.encrypted: throw "CENTRAL_FRESH_NOT_ENCRYPTED"
      secured = true
      print "CENTRAL_FRESH encrypted=true resumed=$resume_ authenticated=$(owner.authenticated)"
    if failure:
      print "CENTRAL_FRESH security-failed=$failure encrypted=$(owner.encrypted)"
      if link_ and not link_.connected:
        catch: print "CENTRAL_FRESH disconnect-reason=$(link_.wait-disconnected)"
      throw failure

// Diagnostic only: allow peer setup to progress before initiating encryption.
// Core 6.3, Vol 3, Part H, 2.4.6 requires the stored key to satisfy a Security
// Request received before encryption setup. This resume-only fixture rejects a
// stronger request instead of re-pairing or silently using a Just Works key.
