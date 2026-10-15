// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .gatt-provider show Provider

/**
The BLE provider extension API.

Subclass $Provider and implement open-transport with a ble.transport.Transport.
  Applications use ble.v2 to access the installed provider. Smaller providers
  are available in ble.service.advertising-provider, scanning-provider and
  central-provider; ble.service.pairing adds pairing policy.

The protocol stack and low-level host hooks live in ble.implementation_ and
  are private SDK implementation details.
*/

export Provider
