// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .mixed-independent-bond-provider as owner
import .mixed-resume-peer as fixture
import .mixed-secure-provider as secure

main: run

run --resume-only/bool=false --private-peer/bool=false:
  radio := secure.Radio
  print "MIXED_INDEPENDENT_BOND PEER resume-only=$resume-only"
  fixture.run --resume-only=resume-only
      --namespace=(private-peer ? "toit.test/ble-mixed-independent-private-v1-peer" : "toit.test/ble-mixed-independent-bond-v1-peer")
      --exchange-identities=private-peer
      --address=owner.PEER
      --radio=radio
  if radio.read-requests != 1000 or radio.closes != 1 or not radio.command-errors.is-empty:
    throw "MIXED_INDEPENDENT_BOND_PEER_COUNTS"
  print "MIXED_INDEPENDENT_BOND_PEER COMPLETE protected-reads=1000 connections=2 closes=1"
