// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import .native as native

/**
An exclusive Linux HCI user-channel transport.

The selected adapter must be powered down before opening. The caller manages
  its powered state after closing. Requires Bluetooth socket privileges.
*/
class LinuxTransport extends native.NativeTransport:
  constructor adapter/int --packet-limit/int=2048:
    super adapter --packet-limit=packet-limit
