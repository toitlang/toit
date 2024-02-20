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

#include "../top.h"

#ifdef TOIT_ESP32

#include <esp_event.h>

#include "../os.h"
#include "../objects_inline.h"
#include "system_esp32.h"

ESP_EVENT_DEFINE_BASE(RUN_EVENT);

namespace toit {

static const int RUN_MAX_DELAY_MS = 5 * 1000;

SystemEventSource::SystemEventSource()
    : EventSource("System", 1)
    , run_cond_(OS::allocate_condition_variable(mutex()))
    , in_run_(false) {
  { HeapTagScope scope(ITERATE_CUSTOM_TAGS + THREAD_SPAWN_MALLOC_TAG);
    FATAL_IF_NOT_ESP_OK(esp_event_loop_create_default());
  }
  FATAL_IF_NOT_ESP_OK(esp_event_handler_register(RUN_EVENT, ESP_EVENT_ANY_ID, on_event, this));
  ASSERT(instance_ == null);
  instance_ = this;
}

SystemEventSource::~SystemEventSource() {
  FATAL_IF_NOT_ESP_OK(esp_event_handler_unregister(RUN_EVENT, ESP_EVENT_ANY_ID, on_event));
  FATAL_IF_NOT_ESP_OK(esp_event_loop_delete_default());
  OS::dispose(run_cond_);
  instance_ = null;
}

void SystemEventSource::run(const std::function<void ()>& func) {
  Locker locker(mutex());
  while (in_run_) {
    OS::wait(run_cond_);
  }
  in_run_ = true;
  is_run_done_ = false;
  { // The call to post an event must be done without holding
    // the lock, because we will wait if the queue is full and
    // we need the lock to handle and thus consume events.
    Unlocker unlock(locker);
    TickType_t ticks = RUN_MAX_DELAY_MS / portTICK_PERIOD_MS;
    FATAL_IF_NOT_ESP_OK(esp_event_post(RUN_EVENT, 0, const_cast<void*>(reinterpret_cast<const void*>(&func)), sizeof(func), ticks));
  }
  while (!is_run_done_) {
    OS::wait(run_cond_);
  }
  in_run_ = false;
  OS::signal(run_cond_);
}

void SystemEventSource::on_register_resource(Locker& locker, Resource* resource) {
  SystemResource* system_resource = static_cast<SystemResource*>(resource);
  esp_event_base_t base = system_resource->event_base();
  int32_t id = system_resource->event_id();
  { // The call to register the event handler must be done
    // without holding the lock, because registering might
    // be forced to wait until any ongoing event handling
    // is done. If the event handling itself is blocked on
    // the mutex in SystemEventSource::on_event, then we
    // would get stuck here if we do not release the lock.
    Unlocker unlock(locker);
    FATAL_IF_NOT_ESP_OK(esp_event_handler_register(base, id, on_event, this));
  }
}

void SystemEventSource::on_unregister_resource(Locker& locker, Resource* resource) {
  SystemResource* system_resource = static_cast<SystemResource*>(resource);
  esp_event_base_t base = system_resource->event_base();
  int32_t id = system_resource->event_id();
  { // The call to unregister the event handler must be done
    // without holding the lock. See comment for the equivalent
    // situation in SystemEventSource::on_register_resource.
    Unlocker unlock(locker);
    FATAL_IF_NOT_ESP_OK(esp_event_handler_unregister(base, id, on_event));
  }
}

void SystemEventSource::on_event(esp_event_base_t base, int32_t id, void* event_data) {
  Thread::ensure_system_thread();
  Locker locker(mutex());

  HeapTagScope scope(ITERATE_CUSTOM_TAGS + EVENT_SOURCE_MALLOC_TAG);
  if (base == RUN_EVENT) {
    const std::function<void ()>* func = reinterpret_cast<const std::function<void ()>*>(event_data);
    (*func)();
    is_run_done_ = true;
    OS::signal(run_cond_);
  } else {
    for (auto resource : resources()) {
      SystemResource* system_resource = static_cast<SystemResource*>(resource);
      if (system_resource->event_base() == base &&
          (system_resource->event_id() == ESP_EVENT_ANY_ID || system_resource->event_id() == id)) {
        SystemEvent event = {base, id, event_data};
        dispatch(locker, system_resource, reinterpret_cast<word>(&event));
      }
    }
  }
}

void SystemEventSource::on_event(void* arg, esp_event_base_t base, int32_t id, void* event_data) {
  unvoid_cast<SystemEventSource*>(arg)->on_event(base, id, event_data);
}

SystemEventSource* SystemEventSource::instance_ = null;

} // namespace toit

#endif // TOIT_ESP32
