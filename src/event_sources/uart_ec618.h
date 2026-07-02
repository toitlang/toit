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
  #include "FreeRTOS.h"
  #include "queue.h"
}

namespace toit {

// Event types for the shared EC618 event source.
// UART and GPIO events are dispatched through the same queue.
struct Event {
  enum Type {
    STOP = 0,
    UART_0,
    UART_1,
    UART_2,
    GPIO_NUM_0,
    // GPIO_NUM_1 through GPIO_NUM_31 follow sequentially.
  };
  Type type;
  word data;

  // Sub-event encoded in `data` for UART_* events.
  enum UartKind {
    UART_KIND_RX = 0,
    UART_KIND_TX_DONE = 1,
    UART_KIND_ERROR = 2,
  };

  static Type gpio_type(int pin) {
    return static_cast<Type>(GPIO_NUM_0 + pin);
  }

  static Type uart_type(int id) {
    return static_cast<Type>(UART_0 + id);
  }

  // I2C controller completion events (after the 32 GPIO slots).
  static Type i2c_type(int id) {
    return static_cast<Type>(GPIO_NUM_0 + 32 + id);
  }

  // A type no event is ever sent for. Used by resources that must exist
  // without an event stream (e.g. a Pin on a pad with no GPIO function,
  // held purely to carry the pad number into a peripheral).
  static Type none_type() {
    return static_cast<Type>(GPIO_NUM_0 + 34);
  }
};

// A resource that carries an event type for matching.
class EventResource : public Resource {
 public:
  EventResource(ResourceGroup* group, Event::Type type)
    : Resource(group)
    , event_type_(type) {}

  Event::Type event_type() const { return event_type_; }

 private:
  Event::Type event_type_;
};

// Shared event source for UART and GPIO on EC618.
// ISR handlers push events into a FreeRTOS queue; the event thread
// dispatches them to matching resources.
class Ec618EventSource : public EventSource, public Thread {
 public:
  static Ec618EventSource* instance() { return instance_; }

  Ec618EventSource();
  ~Ec618EventSource();

  void on_unregister_resource(Locker& locker, Resource* r) override;

  // Called from ISR context.
  static void send_event_from_isr(Event::Type type, word data);
  // Thread-context variant (FromISR queue ops are not safe from tasks).
  static void send_event(Event::Type type, word data);

  QueueHandle_t queue() const { return queue_; }

 private:
  void entry() override;

  static Ec618EventSource* instance_;
  QueueHandle_t queue_;
  bool stop_;
};

}  // namespace toit

#endif  // TOIT_EC618
