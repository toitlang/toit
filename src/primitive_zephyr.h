// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include "top.h"
#ifdef TOIT_ZEPHYR
namespace toit {
// Capture and clear sticky hardware flags once, before application code runs.
void zephyr_capture_reset_reason();
// Called only after all VM resources and native transfer workers are gone.
void zephyr_enter_sleep(int64 request);
}  // namespace toit
#endif
