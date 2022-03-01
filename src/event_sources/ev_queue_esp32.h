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

#include <driver/uart.h>

#include "../resource.h"
#include "../os.h"

namespace toit {

class EventQueueResource : public Resource {
public:
  TAG(UARTResource);

  EventQueueResource(ResourceGroup* group, QueueHandle_t queue)
      : Resource(group)
      , _queue(queue){}

  QueueHandle_t queue() { return _queue; }

private:
  QueueHandle_t _queue; // Note: The queue is freed from the driver uninstall.
};



class EventQueueEventSource : public EventSource, public Thread {
 public:
  static EventQueueEventSource* instance() { return _instance; }

  EventQueueEventSource();
  ~EventQueueEventSource();

 private:
  void entry();

  void on_register_resource(Locker& locker, Resource* r) override;
  void on_unregister_resource(Locker& locker, Resource* r) override;

  static EventQueueEventSource* _instance;

  QueueHandle_t _stop;
  QueueSetHandle_t _queue_set;
};

} // namespace toit
