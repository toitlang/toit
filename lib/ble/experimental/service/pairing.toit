// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..central as central
import ..hci as hci
import ..pairing-attempts as retry
import ..security as security
import ..security-owner show Owner
import .gatt-provider as gatt

/**
Pairing for a GATT provider, as an opt-in.

A provider pairs only when it mixes in $Support: `class MyProvider extends
  gatt.Provider with pairing.Support`. The mixin creates a fresh-pairing
  owner for every accepted central and runs it with the provider's policy
  hooks ($Support.pairing-io-capability, $Support.confirm-pairing,
  $Support.display-passkey, $Support.input-passkey). A provider without it,
  such as the one built into the system container, links none of the
  pairing code. Bond storage builds on top through the provider's
  $gatt.Provider.create-security-owner override.
*/

/** The pairing policy and the owner that carries it out; see the library doc. */
abstract mixin Support:
  abstract pairing-attempts -> retry.Attempts
  abstract pairing-peer-identity link/central.Link -> ByteArray

  /**
  The IO capability to pair with: 0 display only, 1 display yes/no, 2
    keyboard only, 3 no input no output, 4 keyboard display; null disables
    pairing.

  Secure Connections (Just Works, Numeric Comparison, Passkey Entry) and
    legacy pairing (Just Works, Passkey Entry) are supported.
  */
  pairing-io-capability -> int?: return 3

  /** Requires authenticated (MITM-protected) pairing. */
  require-authentication -> bool: return false

  /**
  Confirms a Numeric Comparison $number; overrides must use the device's
    trusted UI. The default refuses.
  */
  confirm-pairing number/int -> bool: return false

  /**
  Shows the six-digit Passkey Entry $passkey for the peer's user to type.

  Called when $pairing-io-capability has a display (0, 1 or 4) and the
    association makes this side the displaying one. The default prints it,
    which suits development on a serial console; a product overrides it.
  */
  display-passkey passkey/int -> none:
    print "BLE passkey: $(%06d passkey)"

  /**
  Returns the passkey the user typed, or null to give up.

  Called when $pairing-io-capability has a keyboard (2 or 4) and this side
    must type what the peer displays. The default gives up.
  */
  input-passkey -> int?: return null

  /**
  Pairs (without bonding) with the accepted central when
    $pairing-io-capability is set. A resumption override returns the owner
    already installed by its host's on-connected hook.
  */
  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    capability := pairing-io-capability
    if capability == null: return null
    return security.Pairing host link --local-address=(link.local-random-address or info.address)
        --local-address-type=(link.local-random-address ? 1 : 0)
        --io-capability=capability
        --require-authentication=require-authentication
        --attempts=pairing-attempts
        --attempt-identity=(pairing-peer-identity link)

  /** Runs the pairing with $confirm-pairing, $display-passkey and $input-passkey. */
  run-security-owner owner/Owner -> none:
    if owner is not security.Pairing: throw "GATT_SECURITY_OWNER_UNSUPPORTED"
    (owner as security.Pairing).run
        --display=(:: display-passkey it)
        --input=(:: input-passkey)
        : | number/int | confirm-pairing number
