// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import .native as native

/**
The Linux transport: the host talks to a Bluetooth adapter through an HCI
  user-channel socket.

$LinuxTransport is the transport a provider's `open-transport` hook returns
  on Linux, and what the application API's Linux entry point installs. The
  adapter must be powered down first; the linux-management library does
  that over the management socket.
*/

/**
An exclusive Linux HCI user-channel transport.

The selected adapter must be powered down before opening. The caller manages
  its powered state after closing. Requires Bluetooth socket privileges.
*/
class LinuxTransport extends native.NativeTransport:
  constructor adapter/int --packet-limit/int=2048:
    super adapter --packet-limit=packet-limit
