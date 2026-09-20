// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once

namespace toit {
// Capture the reset cause before any application or ROM update changes the
// watchdog scratch registers. This does not change the ROM's trial timeout.
void initialize_rp2350_watchdog();
}  // namespace toit
