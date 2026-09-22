// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-flash
import ble.experimental.bond-storage
import ble.experimental.bond-resume
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.security-owner show Owner
import .vhci-central-provider as fixture

// Public test storage key, isolated from the retained peripheral comparison bond.
main:
  store := bond-storage.Storage (bond-flash.FlashRecords "toit.test/ble-central-service") (ByteArray 32: it)
  provider := Provider store
  try:
    fixture.run provider
    if not provider.secured: throw "CENTRAL_BOND_SECURITY_INCOMPLETE"
    print "CENTRAL_BOND COMPLETE resumed=$(provider.resumed) candidate-retained=true"
  finally:
    store.close

class Provider extends fixture.Provider:
  store_/bond-storage.Storage
  saved_/bond.Candidate? := null
  resumed/bool := false
  secured/bool := false
  link_/central.Link? := null

  constructor .store_:
    super

  create-central-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    // Storage errors propagate; only an absent record enables fresh pairing.
    saved_ = store_.load #[1]
    resumed = saved_ != null
    print "CENTRAL_BOND READY mode=$(resumed ? "resume" : "pair")"
    return super controller info receive-limit

  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    link_ = link
    local := link.local-random-address or info.address
    if saved_:
      return RequestTraceResume host link saved_ --local-address=local
    return security.Pairing host link --local-address=local
        --local-address-type=(link.local-random-address ? 1 : 0)
        --attempts=pairing-attempts
        --attempt-identity=(pairing-peer-identity link)
        --io-capability=3
        --no-require-authentication
        --bond

  run-central-security-owner selected/Owner -> none:
    failure := catch: secure_ selected
    if failure:
      print "CENTRAL_BOND security-failed=$failure paired=$(selected.paired) encrypted=$(selected.encrypted)"
      if link_ and not link_.connected:
        reason := catch:
          print "CENTRAL_BOND disconnect-reason=$(link_.wait-disconnected)"
        if reason: print "CENTRAL_BOND disconnect-error=$reason"
      throw failure

  secure_ selected/Owner -> none:
    if resumed:
      (selected as bond-resume.Resume).run
    else:
      (selected as security.Pairing).run (: unreachable) --candidate=: | candidate/bond.Candidate |
        if candidate.peer.address-type != 0 or candidate.peer.address != #[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8]:
          throw "UNEXPECTED_REFERENCE_IDENTITY"
        if candidate.local.address-type != 1 or candidate.local.address != #[1, 0x30, 0x23, 0xf2, 0x3a, 0xc8]:
          throw "UNEXPECTED_LOCAL_IDENTITY"
        store_.save #[1] candidate
        print "CENTRAL_BOND candidate-saved=true"
    secured = true
    print "CENTRAL_BOND encrypted=true resumed=$resumed authenticated=$(selected.authenticated)"

// Bounded public metadata for the unresolved independent resumption failure.
// Never print key material or arbitrary SMP payload bytes.
class RequestTraceResume extends bond-resume.Resume:
  running_/bool := false
  reports_/int := 0

  constructor host/central.Central link/central.Link candidate/bond.Candidate --local-address/ByteArray:
    super host link candidate --local-address=local-address

  run --timeout/Duration=(Duration --s=30) -> none:
    running_ = true
    try:
      super --timeout=timeout
    finally:
      running_ = false

  receive bytes/ByteArray -> none:
    if bytes.size == 2 and bytes[0] == 0x0b and reports_ < 8:
      reports_++
      print "CENTRAL_BOND security-request authreq=$(bytes[1]) running=$running_ encrypted=$encrypted us=$(Time.monotonic-us)"
    super bytes
