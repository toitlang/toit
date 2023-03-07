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

#ifdef TOIT_FREERTOS

#include <esp_event.h>

#include "../os.h"
#include "../objects_inline.h"
#include "system_esp32.h"

ESP_EVENT_DEFINE_BASE(RUN_EVENT);

namespace toit {

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
  FATAL_IF_NOT_ESP_OK(esp_event_post(RUN_EVENT, 0, const_cast<void*>(reinterpret_cast<const void*>(&func)), sizeof(func), portMAX_DELAY));
  while (!is_run_done_) {
    OS::wait(run_cond_);
  }
  in_run_ = false;
  OS::signal(run_cond_);
}

void SystemEventSource::on_register_resource(Locker& locker, Resource* resource) {
  SystemResource* system_resource = static_cast<SystemResource*>(resource);
  FATAL_IF_NOT_ESP_OK(esp_event_handler_register(system_resource->event_base(), system_resource->event_id(), on_event, this));
}

void SystemEventSource::on_unregister_resource(Locker& locker, Resource* resource) {
  SystemResource* system_resource = static_cast<SystemResource*>(resource);
  FATAL_IF_NOT_ESP_OK(esp_event_handler_unregister(system_resource->event_base(), system_resource->event_id(), on_event));
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

#endif // TOIT_FREERTOS
