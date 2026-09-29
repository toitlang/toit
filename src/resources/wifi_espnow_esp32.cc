// Copyright (C) 2024 Toitware ApS.
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

#if defined(TOIT_ESP32) && (!defined(CONFIG_IDF_TARGET_ESP32P4))
#if defined(CONFIG_TOIT_ENABLE_WIFI) || defined(CONFIG_TOIT_ENABLE_ESPNOW)

#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <multi_heap.h>

#include "wifi_espnow_esp32.h"
#include "../os.h"
#include "../resource_pool.h"

namespace toit {

// Only allow one instance of WiFi or ESPNow running.
ResourcePool<int, kInvalidWifiEspnow> wifi_espnow_pool(
  0
);

struct TaggedTask {
  void (*function)(void*);
  void* parameter;
  void* heap_tag;
};

static void run_tagged_task(void* argument) {
  TaggedTask task = *static_cast<TaggedTask*>(argument);
  free(argument);
  vTaskSetThreadLocalStoragePointer(null, MULTI_HEAP_THREAD_TAG_INDEX, task.heap_tag);
  task.function(task.parameter);
}

static TaggedTask* new_tagged_task(void* function, void* parameter) {
  auto task = static_cast<TaggedTask*>(malloc(sizeof(TaggedTask)));
  if (task == null) return null;
  task->function = reinterpret_cast<void (*)(void*)>(function);
  task->parameter = parameter;
  task->heap_tag = reinterpret_cast<void*>(OS::get_heap_tag());
  return task;
}

static int32_t create_tagged_task_pinned_to_core(void* function, const char* name, uint32_t stack_depth,
                                                 void* parameter, uint32_t priority, void* handle, uint32_t core) {
  TaggedTask* task = new_tagged_task(function, parameter);
  if (task == null) return pdFAIL;
  int32_t result = g_wifi_osi_funcs._task_create_pinned_to_core(
      reinterpret_cast<void*>(&run_tagged_task), name, stack_depth, task, priority, handle, core);
  if (result != pdPASS) free(task);
  return result;
}

static int32_t create_tagged_task(void* function, const char* name, uint32_t stack_depth,
                                  void* parameter, uint32_t priority, void* handle) {
  TaggedTask* task = new_tagged_task(function, parameter);
  if (task == null) return pdFAIL;
  int32_t result = g_wifi_osi_funcs._task_create(
      reinterpret_cast<void*>(&run_tagged_task), name, stack_depth, task, priority, handle);
  if (result != pdPASS) free(task);
  return result;
}

wifi_osi_funcs_t* tagged_wifi_osi_funcs() {
  static wifi_osi_funcs_t funcs;
  static bool initialized = false;
  if (!initialized) {
    funcs = g_wifi_osi_funcs;
    funcs._task_create_pinned_to_core = &create_tagged_task_pinned_to_core;
    funcs._task_create = &create_tagged_task;
    initialized = true;
  }
  return &funcs;
}

} // namespace toit

#endif // CONFIG_TOIT_ENABLE_WIFI || CONFIG_TOIT_ENABLE_ESPNOW
#endif // TOIT_ESP32 && !CONFIG_IDF_TARGET_ESP32P4
