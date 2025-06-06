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

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"

#include "../resource.h"
#include "../os.h"
#include "../utils.h"

#define GPIO_QUEUE_SIZE 32
#define UART_QUEUE_SIZE 32

namespace toit {

struct GpioEvent {
  word pin;
  word timestamp;
};

class EventQueueResource : public Resource {
public:
  EventQueueResource(ResourceGroup* group, QueueHandle_t queue)
      : Resource(group)
      , queue_(queue){}

  virtual ~EventQueueResource() {};

  // Might be accessed from interrupt handlers. On the ESP32 it thus needs to be
  // in IRAM, or be marked as inline.
  FORCE_INLINE QueueHandle_t queue() const { return queue_; }

  // Receives one event with a zero timeout.  Provides the data argument for the
  // dispatch call on the event source.  Returns whether an event was available.
  virtual bool receive_event(word* data) { return false; }

  // Checks if the pin number matches the resource it dispatches with the new
  // value.
  // Returns whether the pin number matched.
  virtual bool check_gpio(word pin) { return false; }


private:
  QueueHandle_t queue_; // Note: The queue is freed from the driver uninstall.
};

class EventQueueEventSource : public EventSource, public Thread {
 public:
  static EventQueueEventSource* instance() { return instance_; }

  EventQueueEventSource();
  ~EventQueueEventSource() override;

  // Might be accessed from interrupt handlers. On the ESP32 it thus needs to be
  // in IRAM, or be marked as inline.
  FORCE_INLINE QueueHandle_t gpio_queue() { return gpio_queue_; }

 private:
  void entry() override;

  void on_register_resource(Locker& locker, Resource* r) override;
  void on_unregister_resource(Locker& locker, Resource* r) override;

  static EventQueueEventSource* instance_;

  QueueHandle_t stop_;
  QueueHandle_t gpio_queue_;
  QueueSetHandle_t queue_set_;
};

} // namespace toit
