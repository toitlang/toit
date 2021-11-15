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

class UARTResource : public Resource {
 public:
  TAG(UARTResource);

  UARTResource(ResourceGroup* group, uart_port_t port, QueueHandle_t queue)
      : Resource(group)
      , _port(port)
      , _queue(queue){}

  ~UARTResource() {
    // TODO: Do we need to delete queue?
  }

  uart_port_t port() { return _port; }
  QueueHandle_t queue() { return _queue; }

 private:
  uart_port_t _port;
  QueueHandle_t _queue;
};

// TODO: This could be more generic and handle multiple types of busses.
class UARTEventSource : public EventSource, public Thread {
 public:
  static UARTEventSource* instance() { return _instance; }

  UARTEventSource();
  ~UARTEventSource();

 private:
  void entry();

  void on_register_resource(Locker& locker, Resource* r) override;
  void on_unregister_resource(Locker& locker, Resource* r) override;

  static UARTEventSource* _instance;

  QueueHandle_t _stop;
  QueueSetHandle_t _queue_set;
};

} // namespace toit
