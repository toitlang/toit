// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import system.services show ServiceProvider
import ble.experimental.esp32 as esp32
import ble.experimental.transport as transport
import ble.experimental.service.gatt-provider as ble

/**
The BLE service built into the system container.

On firmware whose Bluetooth controller has no native host, the system
  container serves BLE to every application through $BleServiceProvider, so
  the `ble` package and `ble.v2` work without installing a provider. It
  does not pair and keeps no bonds; a deployment that needs pairing installs
  its own provider (a subclass of the same $ble.Provider with the policy
  hooks it wants), which wins by priority, and the built-in one stays idle:
  it opens the controller only for its own sessions.
*/

/**
The built-in provider: the default policy, one central session and two
  peripheral sessions (two centrals may connect at once), registered as
  strongly unpreferred so that a deployment's provider takes precedence.
*/
class BleServiceProvider extends ble.Provider:
  constructor: super --priority=ServiceProvider.PRIORITY-UNPREFERRED-STRONGLY
  open-transport -> transport.Transport: return esp32.Esp32Transport
  peripheral-session-limit -> int: return 2

/** Installs $BleServiceProvider where the firmware has the controller-only transport. */
install-ble-service -> none:
  if esp32.available: (BleServiceProvider).install
