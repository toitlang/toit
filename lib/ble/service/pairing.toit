// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..implementation_.service.pairing show Support

/**
Adds pairing without bonding to a ble.service.gatt-provider.Provider.

Override pairing-io-capability, require-authentication, confirm-pairing,
  display-passkey and input-passkey to provide the device's trusted pairing UI.
  Protocol and security-owner hooks ending in an underscore are internal.
*/

export Support
