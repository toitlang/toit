// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include "../top.h"
#ifdef TOIT_PICO
namespace toit {
class EventSource;
EventSource* create_rp2350_pio_event_source();
}  // namespace toit
#endif
