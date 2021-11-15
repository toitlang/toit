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

#include <functional>
#include <esp_event.h>

#include "../resource.h"

ESP_EVENT_DECLARE_BASE(WIFI_EVENT);
ESP_EVENT_DECLARE_BASE(IP_EVENT);
ESP_EVENT_DECLARE_BASE(RUN_EVENT);

namespace toit {

struct SystemEvent {
  esp_event_base_t base;
  int32_t id;
  void* event_data;
};

class WifiResourceGroup;

class SystemResource : public Resource {
 public:
  SystemResource(ResourceGroup* group, esp_event_base_t event_base, int32_t event_id = ESP_EVENT_ANY_ID)
      : Resource(group)
      , _event_base(event_base)
      , _event_id(event_id) {}

  esp_event_base_t event_base() { return _event_base; }
  int32_t event_id() { return _event_id; }

 private:
  esp_event_base_t _event_base;
  int32_t _event_id;
};

class SystemEventSource : public EventSource {
 public:
  static SystemEventSource* instance() { return _instance; }

  SystemEventSource();

  ~SystemEventSource();

  void on_event(esp_event_base_t base, int32_t id, void* event_data);

  void on_register_resource(Locker& locker, Resource* resource) override;

  void on_unregister_resource(Locker& locker, Resource* resource) override;

  // Run the function on the system event core.
  void run(const std::function<void ()>& func);

 private:
  static void on_event(void* arg, esp_event_base_t base, int32_t id, void* event_data);

  ConditionVariable* _run_cond;
  bool _in_run;
  bool _is_run_done;

  static SystemEventSource* _instance;
};

} // namespace toit
