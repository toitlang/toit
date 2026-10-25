// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "top.h"
#ifdef TOIT_ZEPHYR
#include "vm.h"
#include "event_sources/timer.h"
#include "event_sources/zephyr.h"
namespace toit {
void VM::load_platform_event_sources() {
  event_manager()->add_event_source(_new TimerEventSource());
  event_manager()->add_event_source(_new ZephyrEventSource());
}
}  // namespace toit
#endif
