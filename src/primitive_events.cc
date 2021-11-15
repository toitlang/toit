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

PRIMITIVE(register_object_notifier) {
  ARGS(Object, object, ResourceGroup, resource_group, Resource, resource);

  ObjectNotifier* notifier = resource->object_notifier();
  if (notifier) {
    notifier->update_object(object);
    return process->program()->null_object();
  }

  notifier = _new ObjectNotifier(process, object);
  if (notifier == null) MALLOC_FAILED;

  ObjectNotifyMessage* message = _new ObjectNotifyMessage(notifier);
  if (message == null) {
    delete notifier;
    MALLOC_FAILED;
  }
  notifier->set_message(message);

  resource_group->event_source()->set_object_notifier(resource, notifier);
  return process->program()->null_object();
}

} // namespace toit
