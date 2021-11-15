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

#include "driver/i2c.h"

#include "../resource.h"
#include "../os.h"

namespace toit {

class GPIOEventSource : public EventSource, public Thread {
 public:
  static GPIOEventSource* instance() { return _instance; }

  GPIOEventSource();
  ~GPIOEventSource();

 private:
  void entry();

  void on_register_resource(Locker& locker, Resource* r) override;
  void on_unregister_resource(Locker& locker, Resource* r) override;

  static void IRAM_ATTR isr_handler(void* arg);

  static GPIOEventSource* _instance;

  bool _stop;
  QueueHandle_t _queue;
};

} // namespace toit
