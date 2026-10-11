// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..implementation_.service.advertising-provider show Provider

/**
Provides non-connectable advertising. Override open-transport to select the
  controller transport, and privacy-irk or privacy-rotation-interval for privacy.

Methods whose names end in an underscore are internal SDK hooks.
*/

export Provider
