// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..implementation_.service.central-provider show Provider

/**
Provides advertising, scanning and outgoing GATT connections. Override
  open-transport, central-session-limit and accept-parameter-requests to
  configure the provider.

Methods whose names end in an underscore are internal SDK hooks.
*/

export Provider
