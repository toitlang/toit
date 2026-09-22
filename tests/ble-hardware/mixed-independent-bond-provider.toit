// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond-flash
import encoding.hex
import .mixed-service-provider as fixture
import .mixed-resume-provider as resume
import .mixed-resume-state as saved

PEER ::= #[0x3a, 0x0b, 0xa0, 0x03, 0xf7, 0x84]

main: run

run --resume-only/bool=false --reverse/bool=false --private-peer/bool=false:
  if reverse and not resume-only: throw "INVALID_ARGUMENT"
  if reverse and private-peer: throw "INVALID_ARGUMENT"
  central-peer := reverse ? saved.LINUX : PEER
  namespace := private-peer ? "toit.test/ble-mixed-independent-private-v1-owner" : "toit.test/ble-mixed-independent-bond-v1-owner"
  state := saved.State (bond-flash.FlashRecords namespace)
      [PEER, saved.LINUX]
      "S3"
      --resume-only=resume-only
      --exchange-identities=private-peer
  try:
    print "MIXED_INDEPENDENT CONFIG receive-acl-packets=4 central-peer=$(hex.encode central-peer.reverse)"
    print "MIXED_INDEPENDENT_BOND OWNER resume-only=$resume-only"
    [false, true].do: | peripheral-first/bool |
      with-timeout --ms=160_000:
        fixture.run peripheral-first (Provider state) --peer-reads=202 --central-peer=central-peer
    state.check (resume-only ? 0 : 2) (resume-only ? 6 : 4)
    print "MIXED_PROVIDER COMPLETE rounds=2"
  finally:
    state.close

class Provider extends resume.Provider:
  constructor state/saved.State: super state
  receive-acl-packets -> int: return 4
