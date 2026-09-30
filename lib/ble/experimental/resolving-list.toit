// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import .hci as hci

/**
Controller-based address resolution.

$configure loads the bonded peers' identities ($Entry) into the controller's
  resolving list and enables resolution; $supported tells whether the
  controller can do it. A provider with privacy calls it on a freshly
  initialized controller so that reports and connection events name peers by
  identity; the application API's Linux entry point does the same.

The controller's resolving list maps bonded peers' identity addresses to
  their IRKs. With resolution enabled the controller resolves the peers'
  resolvable private addresses itself: advertising reports and connection
  events carry the identity (address types 2 and 3), and a central can
  connect to a peer by its identity even though the peer rotates its
  on-air address. Local addresses stay host-managed: the local IRK in each
  entry is zero, so the controller never generates local addresses.
*/

// Resolving list and address resolution: Core 6.3 Vol 6 Part B 6.5 and
// Vol 4 Part E 7.8.38 to 7.8.45.

/** One bonded peer: its identity address (HCI order) and IRK (most significant byte first). */
class Entry:
  address-type/int
  address/ByteArray
  irk/ByteArray

  constructor --.address-type --.address --.irk:
    if not 0 <= address-type <= 1 or address.size != 6 or irk.size != 16: throw "INVALID_ARGUMENT"

/** Whether the controller has link-layer privacy and the resolving list commands. */
supported info/hci.Capabilities -> bool:
  // LE feature LL Privacy; Add Device, Clear, Read Size (octet 34 bits 3, 5,
  // 6); Set Address Resolution Enable and RPA Timeout (octet 35 bits 1, 2).
  return info.le-features[0] & 0x40 != 0 and
      info.commands[34] & 0x68 == 0x68 and
      info.commands[35] & 0x06 == 0x06

/**
Loads $entries into the controller's resolving list and enables resolution.

Call on a freshly initialized controller, before its owner starts link
  procedures. Also unmasks LE Enhanced Connection Complete, which reports
  the resolved identity. Throws HCI_PRIVACY_UNSUPPORTED when the controller
  lacks it (see $supported) and HCI_RESOLVING_LIST_FULL when the entries do
  not fit.
*/
configure controller/hci.Controller info/hci.Capabilities entries/List
    --rotation/Duration=(Duration --s=900) -> none:
  if not (supported info): throw "HCI_PRIVACY_UNSUPPORTED"
  if not 1 <= rotation.in-s <= 3600: throw "INVALID_ARGUMENT"
  size := (controller.command 0x202a)[0]
  if entries.size > size: throw "HCI_RESOLVING_LIST_FULL"
  controller.command 0x202d #[0]
  controller.command 0x2029
  // Device privacy mode (7.8.77) also accepts a bonded peer that uses its
  // identity address on air, where the controller supports choosing it.
  privacy-mode := info.commands[39] & 0x04 != 0
  entries.do: | entry/Entry |
    parameters := ByteArray 39
    parameters[0] = entry.address-type
    parameters.replace 1 entry.address
    16.repeat: parameters[7 + it] = entry.irk[15 - it]
    controller.command 0x2027 parameters
    if privacy-mode: controller.command 0x204e (#[entry.address-type] + entry.address + #[1])
  timeout := ByteArray 2
  io.LITTLE-ENDIAN.put-uint16 timeout 0 rotation.in-s
  controller.command 0x202e timeout
  controller.command 0x202d #[1]
  // Keep the host's defaults (Data Length Change, PHY Update Complete) and
  // add Enhanced Connection Complete (bit 9).
  controller.command hci.LE-SET-EVENT-MASK #[0x5f, 0x0a, 0, 0, 0, 0, 0, 0]
