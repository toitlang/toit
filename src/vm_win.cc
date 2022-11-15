// Copyright (C) 2021 Toitware ApS.
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

#ifdef TOIT_WINDOWS

#include "objects_inline.h"
#include "vm.h"

#include "event_sources/timer.h"
#include "event_sources/tls.h"
#include "event_sources/event_win.h"

namespace toit {

void VM::load_platform_event_sources() {
  // The Windows host implementation is using stdlib in multiple threads. The standard library collections
  // calls new behind the scenes in some cases. The AllowThrowingNew RII is not thread safe, so for this host
  // implementation the throwing_new_allowed is enabled globally.
  toit::throwing_new_allowed = true;
  event_manager()->add_event_source(_new TimerEventSource());
  event_manager()->add_event_source(_new TLSEventSource());
  event_manager()->add_event_source(_new WindowsEventSource());
}

} // namespace toit

#endif // TOIT_WINDOWS
