// Copyright (C) 2026 Toit contributors.
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

#pragma once

#ifdef TOIT_EC618

#include "../resource.h"
#include "../os.h"
#include "../top.h"

extern "C" {
  #include "ps_event_callback.h"
}

namespace toit {

// Wraps a PS event for delivery to Toit resources.
struct CellularEvent {
  PsEventID event_id;
  uint32 param_len;
  // Event data is copied inline after this struct.
  uint8 data[];
};

// Event source for cellular URC (unsolicited result codes) from the
// EC618 protocol stack. Registered with registerPSEventCallback.
class CellularEventSource : public EventSource {
 public:
  static CellularEventSource* instance() { return instance_; }

  CellularEventSource();
  ~CellularEventSource();

 private:
  static int32_t on_urc(PsEventID event_id, void* param, uint32_t param_len);

  static CellularEventSource* instance_;
};

}  // namespace toit

#endif  // TOIT_EC618
