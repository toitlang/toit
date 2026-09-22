// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.central
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.security-owner show Owner
import .vhci-central-provider as fixture

main: fixture.run Provider

class Provider extends fixture.Provider:
  numeric_/bool
  constructor --numeric/bool=false:
    numeric_ = numeric
    super
  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    return security.Pairing host link --local-address=(link.local-random-address or info.address)
        --local-address-type=(link.local-random-address ? 1 : 0)
        --attempts=pairing-attempts
        --attempt-identity=(pairing-peer-identity link)
        --io-capability=(numeric_ ? 1 : 3)
        --require-authentication=numeric_
  run-central-security-owner selected/Owner -> none:
    (selected as security.Pairing).run: | number/int |
      if not numeric_: throw "UNEXPECTED_NUMERIC_COMPARISON"
      // Test-only approval: the independent peer checks this fresh number.
      print "CENTRAL_PAIRING NUMERIC value=$number fixture-approval=true"
      true
    if not selected.encrypted or selected.authenticated != numeric_: throw "UNEXPECTED_CENTRAL_SECURITY"
    print "CENTRAL_PAIRING encrypted=true authenticated=$(selected.authenticated) association=$(numeric_ ? "numeric-comparison" : "just-works")"
