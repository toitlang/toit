// Copyright (C) 2018 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "top.h"

#ifdef TOIT_LINUX

#include "objects_inline.h"
#include "vm.h"

#include "event_sources/epoll_linux.h"
#include "event_sources/lwip_esp32.h"
#include "event_sources/subprocess.h"
#include "event_sources/timer.h"
#include "event_sources/tls.h"

namespace toit {

void VM::load_platform_event_sources() {
#if defined(TOIT_USE_LWIP)
  event_manager()->add_event_source(_new LwipEventSource());
#endif
  // TODO(Lau): add new event source to other platforms.
  event_manager()->add_event_source(_new TimerEventSource());
  event_manager()->add_event_source(_new EpollEventSource());
  event_manager()->add_event_source(_new SubprocessEventSource());
  event_manager()->add_event_source(_new TlsEventSource());
}

} // namespace toit

#endif // TOIT_LINUX
