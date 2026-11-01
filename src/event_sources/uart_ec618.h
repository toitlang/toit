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
#include "mailbox_ec618.h"

extern "C" {
  #include "FreeRTOS.h"
  #include "queue.h"
}

namespace toit {

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

// Shared event source for EC618 peripherals. The queue carries GPIO edges and
// wake-up tokens for persistent peripheral state retained in the mailbox.
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
  void dispatch_event(Locker& locker, Event::Type type, word data);

  static Ec618EventSource* instance_;
  QueueHandle_t queue_;
  Ec618EventMailbox mailbox_;
  bool stop_;
};

}  // namespace toit

#endif  // TOIT_EC618
