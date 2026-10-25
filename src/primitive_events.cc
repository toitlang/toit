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

#include "resource.h"
#include "process.h"
#include "process_group.h"
#include "objects_inline.h"
#include "primitive.h"
#include "vm.h"

namespace toit {

MODULE_IMPLEMENTATION(events, MODULE_EVENTS)

PRIMITIVE(read_state) {
  ARGS(ResourceGroup, resource_group, Resource, resource);

  return Smi::from(resource_group->event_source()->read_state(resource));
}

PRIMITIVE(register_monitor_notifier) {
  ARGS(Object, monitor, ResourceGroup, group, Resource, resource);

  EventSource* source = group->event_source();
  if (!source->update_resource_monitor(resource, process, monitor)) FAIL(MALLOC_FAILED);
  return process->null_object();
}

PRIMITIVE(unregister_monitor_notifier) {
  ARGS(ByteArray, group_proxy, ByteArray, resource_proxy);

  // Don't use the typed unpacking macros, as they fail for closed
  // resources, and the notifier may be disposed after the resource
  // has been closed.
  if (!group_proxy->has_external_address() ||
      group_proxy->external_tag() < ResourceGroup::tag_min ||
      group_proxy->external_tag() > ResourceGroup::tag_max ||
      !resource_proxy->has_external_address() ||
      resource_proxy->external_tag() < Resource::tag_min ||
      resource_proxy->external_tag() > Resource::tag_max) {
    FAIL(WRONG_OBJECT_TYPE);
  }
  ResourceGroup* group = group_proxy->as_external<ResourceGroup>();
  Resource* resource = resource_proxy->as_external<Resource>();
  if (group && resource) {
    group->event_source()->delete_resource_monitor(resource);
  }
  return process->null_object();
}

} // namespace toit
