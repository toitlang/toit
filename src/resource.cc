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
#include "objects_inline.h"
#include "os.h"
#include "vm.h"
#include "process.h"

namespace toit {

Resource::~Resource() {
  delete _object_notifier;
}

ResourceGroup::ResourceGroup(Process* process, EventSource* event_source)
  : _process(process)
  , _event_source(event_source) {
  if (event_source != null) {
    event_source->register_resource_group(this);
  }
  process->add_resource_group(this);
}

void ResourceGroup::tear_down() {
  while (Resource* resource = _resources.remove_first()) {
    if (_event_source != null) {
      _event_source->unregister_resource(resource);
    }
    on_unregister_resource(resource);
    resource->make_deletable();
  }

  if (_event_source != null) {
    _event_source->unregister_resource_group(this);
  }

  _process->remove_resource_group(this);
  delete this;
}

IntResource* ResourceGroup::register_id(word id) {
  IntResource* resource = _new IntResource(this, id);
  if (resource) register_resource(resource);
  return resource;
}

void ResourceGroup::register_resource(Resource* resource) {
  _resources.prepend(resource);
  on_register_resource(resource);

  if (_event_source != null) {
    _event_source->register_resource(resource);
  }
}

void ResourceGroup::unregister_id(word id) {
  for (auto it : _resources) {
    IntResource* resource = static_cast<IntResource*>(it);
    if (resource->id() == id) {
      unregister_resource(resource);
      return;
    }
  }
}

void ResourceGroup::unregister_resource(Resource* resource) {
  if (_event_source != null) {
    _event_source->unregister_resource(resource);
  }

  if (_resources.is_linked(resource)) {
    _resources.unlink(resource);
    on_unregister_resource(resource);
  }

  delete resource;
}

EventSource::EventSource(const char* name, int lock_level)
    : _mutex(OS::allocate_mutex(lock_level, "EventSource"))
    , _name(name) {
}

EventSource::~EventSource() {
  ASSERT(_resources.is_empty());
  OS::dispose(_mutex);
}

bool EventSource::is_locked() {
  return OS::is_locked(_mutex);
}

void EventSource::register_resource(Resource* r) {
  Locker locker(_mutex);
  ASSERT(reinterpret_cast<uword>(r) > 1000000);
  _resources.append(r);
  on_register_resource(locker, r);
}

void EventSource::unregister_resource(Resource* r) {
  Locker locker(_mutex);
  unregister_resource(locker, r);
}

void EventSource::unregister_resource(Locker& locker, Resource* r) {
  if (_resources.is_linked(r)) _resources.unlink(r);
  // Be sure to notify to wake up any ongoing uses.
  try_notify(r, locker, true);
  on_unregister_resource(locker, r);
}

void EventSource::register_resource_group(ResourceGroup* resource_group) {
}

void EventSource::unregister_resource_group(ResourceGroup* resource_group) {
}

void EventSource::set_state(word id, uint32_t state) {
  Locker locker(_mutex);
  set_state(locker, find_resource_by_id(locker, id), state);
}

void EventSource::set_state(Resource* r, uint32_t state) {
  Locker locker(_mutex);
  set_state(locker, r, state);
}

void EventSource::set_state(const Locker& locker, Resource* r, uint32_t state) {
  r->set_state(state);
  try_notify(r, locker);
}

void EventSource::dispatch(Resource* r, word data) {
  Locker locker(_mutex);
  dispatch(locker, r, data);
}

void EventSource::dispatch(const Locker& locker, Resource* r, word data) {
  r->set_state(r->resource_group()->on_event(r, data, r->state()));
  try_notify(r, locker);
}

// Called on the event source's thread, while holding the event source's lock.
void EventSource::try_notify(Resource* r, const Locker& locker, bool force) {
  if (!force && r->state() == 0) return;

  if (r->object_notifier() != null) {
    r->object_notifier()->notify();
  }
}

void EventSource::set_object_notifier(Resource* r, ObjectNotifier* notifier) {
  Locker locker(_mutex);

  if (notifier) {
    ASSERT(r->object_notifier() == null);
    r->set_object_notifier(notifier);
    if (r->state() != 0) notifier->notify();
  } else {
    delete r->object_notifier();
    r->set_object_notifier(null);
  }
}

uint32_t EventSource::read_state(Resource* r) {
  Locker locker(_mutex);

  uint32_t state = r->state();
  r->set_state(0);
  return state;
}

IntResource* EventSource::find_resource_by_id(const Locker& locker, word id) {
  for (auto it : _resources) {
    IntResource* r = static_cast<IntResource*>(it);
    if (r->id() == id) return r;
  }
  return null;
}

void LazyEventSource::unregister_resource_group(ResourceGroup* resource_group) {
  unuse();
}

bool LazyEventSource::use() {
  Locker locker(OS::global_mutex());
  if (_usage == 0) {
    HeapTagScope scope(ITERATE_CUSTOM_TAGS + EVENT_SOURCE_MALLOC_TAG);
    if (!start()) return false;
  }
  _usage++;
  return true;
}

void LazyEventSource::unuse() {
  Locker locker(OS::global_mutex());
  if (--_usage == 0) {
    stop();
  }
}

} // namespace toit
