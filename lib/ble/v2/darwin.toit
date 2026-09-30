// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..experimental.service.darwin-provider as darwin
import .adapter

/**
The application API on macOS.

macOS has no BLE provider container; $open installs one in the calling
  process, over CoreBluetooth, and returns an $Adapter that uninstalls it
  on close. Peers are the platform's identifiers (`PlatformPeer`), and what
  macOS keeps to itself (PHY, connection parameters, transmit power,
  security, the identity of connected centrals) reports BLE_UNSUPPORTED;
  see `ble.experimental.service.darwin-provider`.
*/

/** Opens the Mac's Bluetooth adapter. */
open -> Adapter:
  provider := install
  adapter/Adapter? := null
  try:
    adapter = Adapter.with-cleanup_ --on-close=:: provider.uninstall
    return adapter
  finally:
    if not adapter: provider.uninstall

/**
Installs the provider in this process without opening an adapter, for the
  `ble` package: after this, its `Adapter` finds the provider. Uninstall it
  (`provider.uninstall`) when done.
*/
install -> darwin.Provider:
  provider := darwin.Provider
  provider.install
  return provider
