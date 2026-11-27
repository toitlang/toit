// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once

namespace toit {
// Capture elapsed low-power time before starting the VM.
void initialize_rp2350_time();
// Save the awake clock immediately before resetting the always-on sleep timer.
void prepare_rp2350_time_for_sleep();
}  // namespace toit
