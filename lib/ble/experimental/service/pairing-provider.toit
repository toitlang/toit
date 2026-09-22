// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import ..central as central
import ..hci as hci
import ..security as security
import ..security-owner show Owner
import .gatt-provider as gatt

/**
Adds fresh Secure Connections pairing to the GATT provider.

Selects the same application RPC API as the ordinary provider. Trusted code
  must still override pairing-io-capability to enable pairing and provide its
  confirmation/authentication policy. Merely importing this class does not
  enable pairing. Retry history is shared across sessions through the inherited
  provider hooks. Bond resumption and candidate persistence remain explicit
  security-owner overrides; no application RPC supplies key material.

Choosing the ordinary gatt-provider avoids retaining this pairing implementation
  in deployments that do not need it.
*/
abstract class Provider extends gatt.Provider:
  constructor: super

  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    capability := pairing-io-capability
    if capability == null: return null
    return security.Pairing host link --local-address=(link.local-random-address or info.address)
        --local-address-type=(link.local-random-address ? 1 : 0)
        --io-capability=capability
        --require-authentication=require-authentication
        --attempts=pairing-attempts
        --attempt-identity=(pairing-peer-identity link)


  run-security-owner owner/Owner -> none:
    (owner as security.Pairing).run: | number/int | confirm-pairing number
