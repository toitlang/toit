// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond-flash
import ble.experimental.bounded-central as bounded
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.security-owner show Owner
import ble.experimental.service.mixed-provider as policy
import .mixed-service-provider as fixture
import .mixed-secure-provider as secure
import .mixed-resume-state as saved

main: run

run --resume-only/bool=false:
  state := saved.State (bond-flash.FlashRecords "toit.test/ble-mixed-resume-001-s3")
      [saved.PEER, saved.LINUX]
      "S3"
      --resume-only=resume-only
  try:
    [false, true].do: | peripheral-first/bool |
      with-timeout --ms=160_000: fixture.run peripheral-first (Provider state) --peer-reads=202
    state.check (resume-only ? 0 : 2) (resume-only ? 6 : 4)
    print "MIXED_PROVIDER COMPLETE rounds=2"
  finally:
    state.close

class Provider extends secure.Provider:
  state_/saved.State
  constructor .state_: super

  create-shared-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    policy.configure controller info
    if info.address != saved.S3: throw "MIXED_RESUME_WRONG_BOARD"
    return Host controller info receive-limit state_

  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    return (host as Host).owners[link.info.handle]

  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    return (host as Host).owners[link.info.handle]

  run-central-security-owner selected/Owner -> none: state_.secure selected 0
  run-security-owner selected/Owner -> none: state_.secure selected 1

class Host extends bounded.Central:
  state_/saved.State
  local_/ByteArray
  owners/Map ::= {:}
  constructor controller/hci.Controller info/hci.Capabilities receive-limit/int .state_:
    local_ = info.address
    super controller --acl-length=info.acl-length --acl-count=info.acl-count
        --receive-limit=receive-limit
        --link-limit=2
  on-connected link/central.Link -> none:
    owners[link.info.handle] = state_.owner this link local_
