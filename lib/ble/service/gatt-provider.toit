// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..implementation_.service.gatt-provider show Provider

/**
Provides advertising, scanning and GATT connections in both roles. Override
  open-transport to select the controller transport. Session limits,
  mixed-role-sessions, privacy-irk, resolving-list, max-attributes and
  advertising-timeout configure the supported provider policy. Mix in
  ble.service.pairing.Support to enable pairing without bonding.

Methods whose names end in an underscore are internal SDK hooks.
*/

export Provider
