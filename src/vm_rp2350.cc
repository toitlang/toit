// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license that can be
// found in the LICENSE file.
#include "top.h"
#ifdef TOIT_RP2350
#include "vm.h"
#include "event_sources/timer.h"
#include "event_sources/tls.h"
#include "event_sources/event_rp2350.h"
#include "event_sources/gpio_rp2350.h"
#include "event_sources/uart_rp2350.h"
#include "event_sources/i2c_rp2350.h"
#include "event_sources/spi_rp2350.h"
#include "event_sources/stdio_rp2350.h"
namespace toit {
void VM::load_platform_event_sources() {
  event_manager()->add_event_source(_new TimerEventSource());
  event_manager()->add_event_source(_new TlsEventSource());
  // Sources are destroyed in reverse order. Keep the dispatcher alive until
  // every peripheral has detached and disabled its interrupts.
  auto dispatcher = _new Rp2350EventDispatcher();
  event_manager()->add_event_source(dispatcher);
  event_manager()->add_event_source(_new Rp2350GpioEventSource());
  event_manager()->add_event_source(_new Rp2350UartEventSource());
  event_manager()->add_event_source(create_rp2350_i2c_event_source());
  event_manager()->add_event_source(create_rp2350_spi_event_source());
  event_manager()->add_event_source(_new Rp2350StdinEventSource());
  dispatcher->start();
}
}  // namespace toit
#endif
