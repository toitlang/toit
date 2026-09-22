// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import .hci as hci

// Core 6.3, Vol 4, Part E, section 7.8.27, LE_States table.
CONNECTABLE-ADVERTISING-WITH-CENTRAL ::= 35
INITIATING-WITH-PERIPHERAL ::= 41

/** Reads controller support for legacy radio states without changing radio state. */
read controller/hci.Controller -> States:
  return States (controller.command 0x201c)

/**
An owned snapshot of the controller's legacy LE Supported States bit field.

This describes supported state/role combinations, not connection counts,
  extended advertising support, or measured concurrent performance. In particular,
  bits 35 and 41 describe the two establishment orders for mixed-role links;
  they are not a general guarantee of multi-link capacity or service support.
*/
class States:
  bytes_/ByteArray

  constructor bytes/ByteArray:
    if bytes.size != 8: throw "HCI_MALFORMED_RESPONSE"
    bytes_ = bytes.copy

  /** Returns a copy of all bits, including reserved bits for diagnostics. */
  bytes -> ByteArray: return bytes_.copy

  /**
  Tests a defined bit in the Core 6.3 table (0 through 41).

  An all-zero controller response establishes no support. Reserved bits are
    retained for diagnostics but cannot be queried as known capabilities.
  */
  supports bit/int -> bool:
    if not 0 <= bit <= 41: throw "INVALID_ARGUMENT"
    return bytes_[bit >> 3] & (1 << (bit & 7)) != 0
