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

#include "../event_sources/timer.h"
#include "../resource.h"
#include "../objects_inline.h"
#include "../process.h"

namespace toit {

class TimerResourceGroup : public ResourceGroup {
 public:
  TAG(TimerResourceGroup);
  TimerResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* resource, word data, uint32_t state) {
    return state | 1;
  }
};

MODULE_IMPLEMENTATION(timer, MODULE_TIMER)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  TimerResourceGroup* resource_group = _new TimerResourceGroup(process, TimerEventSource::instance());
  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(create) {
  ARGS(TimerResourceGroup, resource_group);

  ByteArray* timer_proxy = process->object_heap()->allocate_proxy();
  if (timer_proxy == null) ALLOCATION_FAILED;


  Timer* timer = _new Timer(resource_group);
  if (timer == null) MALLOC_FAILED;

  resource_group->register_resource(timer);
  timer_proxy->set_external_address(timer);

  return timer_proxy;
}

PRIMITIVE(arm) {
  ARGS(Timer, timer, int64, usec);

  TimerEventSource::instance()->arm(timer, usec);

  return process->program()->null_object();
}

PRIMITIVE(delete) {
  ARGS(TimerResourceGroup, resource_group, Timer, timer);

  resource_group->unregister_resource(timer);

  timer_proxy->clear_external_address();

  return process->program()->null_object();
}

} // namespace toit
