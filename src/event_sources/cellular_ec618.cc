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

#include "../top.h"

#ifdef TOIT_EC618

#include "cellular_ec618.h"

namespace toit {

CellularEventSource* CellularEventSource::instance_ = null;

CellularEventSource::CellularEventSource()
    : EventSource("Cellular", 1) {
  ASSERT(instance_ == null);
  instance_ = this;
  registerPSEventCallback(PS_GROUP_ALL_MASK, on_urc);
}

CellularEventSource::~CellularEventSource() {
  deregisterPSEventCallback(on_urc);
  instance_ = null;
}

int32_t CellularEventSource::on_urc(PsEventID event_id, void* param, uint32_t param_len) {
  if (instance_ == null) return 0;

  // The URC callback may come from any thread. Ensure we have a system
  // thread registered so mutex operations work.
  Thread::ensure_system_thread();

  Locker locker(instance_->mutex());
  // Dispatch to all registered resources.
  for (auto r : instance_->resources()) {
    instance_->dispatch(locker, r, static_cast<word>(event_id));
  }
  return 0;
}

}  // namespace toit

#endif  // TOIT_EC618
