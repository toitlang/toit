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
run --resume/bool --resume-delay-ms/int=0 --wait-for-security-request/bool=false:
  if not 0 <= resume-delay-ms <= 1_000 or (resume-delay-ms != 0 and not resume) or
      (wait-for-security-request and resume-delay-ms == 0):
    throw "INVALID_ARGUMENT"
  store := bond-storage.Storage (bond-flash.FlashRecords "toit.test/central-fresh-001") (ByteArray 32: it)
  try:
    provider := Provider store resume resume-delay-ms wait-for-security-request
    with-timeout --ms=60_000: base.run provider
    if not provider.secured: throw "CENTRAL_FRESH_SECURITY_INCOMPLETE"
    print "CENTRAL_FRESH COMPLETE resumed=$resume candidate-retained=true"
  finally:
    store.close

class Provider extends base.Provider:
  store_/bond-storage.Storage
  resume_/bool
  resume-delay-ms_/int
  wait-for-security-request_/bool
  candidate_/bond.Candidate? := null
  link_/central.Link? := null
  secured/bool := false

  constructor .store_ .resume_ .resume-delay-ms_ .wait-for-security-request_: super

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
      if resume-delay-ms_ != 0:
        return DelayedResume host link candidate_ resume-delay-ms_ --on-request=wait-for-security-request_
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
class DelayedResume extends diagnostics.RequestTraceResume:
  probe-link_/central.Link
  delay-ms_/int
  waiting_/bool := false
  requests_/int := 0
  on-request_/bool
  stored-authenticated_/bool
  request-error_/string? := null
  requested_/monitor.Latch ::= monitor.Latch

  constructor host/central.Central .probe-link_ candidate/bond.Candidate .delay-ms_ --on-request/bool=false:
    on-request_ = on-request
    stored-authenticated_ = candidate.authenticated
    super host probe-link_ candidate --local-address=IDENTITY

  run --timeout/Duration=(Duration --s=30) -> none:
    waiting_ = true
    succeeded := false
    try:
      with-timeout timeout:
        print "CENTRAL_FRESH RESUME_DELAY_BEGIN ms=$delay-ms_ on-request=$on-request_ us=$(Time.monotonic-us)"
        if on-request_:
          with-timeout --ms=delay-ms_: requested_.get
        else:
          sleep --ms=delay-ms_
        waiting_ = false
        print "CENTRAL_FRESH RESUME_DELAY_END connected=$(probe-link_.connected) requests=$requests_ us=$(Time.monotonic-us)"
        if not probe-link_.connected: throw "HCI_LINK_DISCONNECTED"
        if request-error_: throw request-error_
        super --timeout=timeout
        succeeded = true
    finally:
      waiting_ = false
      if not succeeded: close

  receive bytes/ByteArray -> none:
    if waiting_ and bytes.size == 2 and bytes[0] == 0x0b:
      requests_++
      if requests_ <= 8:
        print "CENTRAL_FRESH DELAY_SECURITY_REQUEST authreq=$(bytes[1]) us=$(Time.monotonic-us)"
      if bytes[1] & 4 != 0 and not stored-authenticated_:
        request-error_ = "BLE_BOND_INSUFFICIENT_AUTHENTICATION"
        // Resume.receive rejects pairing while encryption has not started.
        super bytes
      if not requested_.has-value: requested_.set true
      return
    super bytes
