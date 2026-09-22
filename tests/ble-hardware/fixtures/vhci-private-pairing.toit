// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.privacy
import encoding.hex
import .vhci-pairing as fixture

main:
  // Public Core 6.3 Appendix D.7 test material, never an operational identity.
  irk := hex.decode "ec0234a357c8ad05341010a60a397d9b"
  address := privacy.from-prand irk #[0x70, 0x81, 0x94]
  if address != #[0xaa, 0xfb, 0x0d, 0x94, 0x81, 0x70]: throw "UNEXPECTED_RPA"
  if not (privacy.resolves irk address 1): throw "RPA_NOT_RESOLVED"
  print "VHCI_PRIVATE_PAIRING address=70:81:94:0D:FB:AA type=random fixture-only=true"
  fixture.run --local-random-address=address
