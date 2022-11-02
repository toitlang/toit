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

#pragma once

#include "entropy_mixer.h"

namespace toit {

class EventSource;
class EventSourceManager;
class Scheduler;

class VM {
 public:
  // Create a new VM. Only one VM should exist at any given point in time.
  // The compiler uses a VM with the associated event sources. The runtime
  // starts all the platform event sources.
  VM();
  ~VM();

  static VM* current() { return current_; }

  // Load the platform specific integrations. Without this call, the VM
  // will have no platform features available.
  void load_platform_event_sources();

  Scheduler* scheduler() const { return scheduler_; }

  EventSourceManager* event_manager() const { return event_manager_; }
  EventSource* nop_event_source() const { return _nop_event_source; }

 private:
  static VM* current_;
  Scheduler* scheduler_;

  EventSourceManager* event_manager_ = null;
  EventSource* _nop_event_source = null;
};

} // namespace toit
