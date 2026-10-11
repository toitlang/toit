// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..implementation_.service.scanning-provider show Provider

/**
Provides advertising and scanning. Override open-transport to select the
  controller transport, and scan-local-random-address or
  scan-address-rotation-interval for scanning address policy.

Methods whose names end in an underscore are internal SDK hooks.
*/

export Provider
