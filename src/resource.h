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

#include "heap.h"
#include "heap_report.h"
#include "linked.h"
#include "os.h"
#include "tags.h"
#include "top.h"

namespace toit {

class EventSource;
class Resource;
class ResourceGroup;

// Resource is linked into two different linked lists, so we have to make
// use of the arbitrary N template argument to distinguish the two.
typedef DoubleLinkedList<Resource, 1> ResourceList;
typedef DoubleLinkedList<Resource, 2> ResourceListFromEventSource;

class Resource : public ResourceList::Element, public ResourceListFromEventSource::Element {
 public:
  TAGS(Resource);
  explicit Resource(ResourceGroup* resource_group)
    : _resource_group(resource_group)
    , _state(0)
    , _object_notifier(null) {}

  virtual ~Resource();

  template<typename T>
  T as() { return static_cast<T>(this); }

  ResourceGroup* resource_group() { return _resource_group; }

  uint32_t state() { return _state; }
  void set_state(uint32_t state) { _state = state; }

  ObjectNotifier* object_notifier() { return _object_notifier; }
  void set_object_notifier(ObjectNotifier* object_notifier) { _object_notifier = object_notifier; }

  // When a resource group is torn down we call this.  Normally it deletes it, but
  // it may just mark it for deletion in case there are still other references to it,
  // eg from callbacks at the OS level.
  virtual void make_deletable() {
    delete this;
  }

private:
  ResourceGroup* _resource_group;

  uint32_t _state;
  // The object_notifier is manipulated under the EventSource lock.
  ObjectNotifier* _object_notifier;
};

class IntResource : public Resource {
 public:
  TAG(IntResource);
  IntResource(ResourceGroup* group, word id)
    : Resource(group)
    , _id(id) {}

  word id() { return _id; }

 private:
  word _id;
};

typedef LinkedList<ResourceGroup> ResourceGroupListFromProcess;

// A resource group is a sort of namespace for Resources.  For example, there
// is a ResourceGroup for TCP sockets, where the Resources correspond to open
// file descriptors.  For each subclass of ResourceGroup there is an instance
// per process (in a linked list hanging off the process).  A system-wide
// EventSource instance also has the resource group in a linked list.
class ResourceGroup : public ResourceGroupListFromProcess::Element {
 public:
  TAGS(ResourceGroup);
  explicit ResourceGroup(Process* process) : ResourceGroup(process, null) {}
  ResourceGroup(Process* process, EventSource* event_source);

  /**
   * Tear down the resource group and all containing resources. This will
   * deallocate all resources, including the resource group itself.
   * This method should always be called instead of ~ResourceGroup.
   */
  virtual void tear_down();

  Process* process() { return _process; }

  EventSource* event_source() { return _event_source; }

  IntResource* register_id(word id);
  void register_resource(Resource* resource);

  void unregister_id(word id);
  void unregister_resource(Resource* resource);

 protected:
  virtual ~ResourceGroup() {}

  // Called on an EventSource thread while holding the EventSource lock.
  virtual uint32_t on_event(Resource* resource, word data, uint32_t state) { return 0; }

  // Called on the Toit process thread.
  virtual void on_register_resource(Resource* r) {}
  virtual void on_unregister_resource(Resource* r) {}

  // Avoid direct deletes of ResourceGroup - use tear_down.
  void operator delete(void* p) {
    free(p);
  }

 private:
  Process* const _process;
  EventSource* _event_source;
  ResourceList _resources;

  friend class EventSource;
};
typedef LinkedList<EventSource> EventSourceList;

template <typename Resource>
class AutoUnregisteringResource {
 public:
  AutoUnregisteringResource(ResourceGroup* group, Resource* resource) : _group(group), _resource(resource) {}

  ~AutoUnregisteringResource() {
    if (_resource) {
      _group->unregister_resource(_resource);
    }
  }

  void set_external_address(ByteArray* proxy) {
    proxy->set_external_address(_resource);
    _resource = null;
  }

 private:
  ResourceGroup* _group;
  Resource* _resource;
};

// A resource group for resource objects that only need freeing when the
// process exits, but don't have any other interesting activities, like event
// sources.
class SimpleResourceGroup : public ResourceGroup {
 public:
  TAG(SimpleResourceGroup);
  explicit SimpleResourceGroup(Process* process)
    : ResourceGroup(process) {
  }

  ~SimpleResourceGroup() {
  }
};

// A resource for resource objects that only need freeing when the process
// exits, but don't have any other interesting activities, like event sources.
class SimpleResource : public Resource {
 public:
  explicit SimpleResource(SimpleResourceGroup* group) : Resource(group) {
    if (group != null) {
      group->register_resource(this);
    }
  }
};

// Similar to AllocationManager, but for SimpleResources.
template <typename T>
class SimpleResourceAllocationManager {
 public:
  SimpleResourceAllocationManager(T* ptr)
      : _ptr(ptr) {
    SimpleResource* this_class_is_for_subclasses_of_simple_resource = ptr;
    USE(this_class_is_for_subclasses_of_simple_resource);
  }

  ~SimpleResourceAllocationManager() {
    if (_ptr) {
      _ptr->resource_group()->unregister_resource(_ptr);
      _ptr = null;
    }
  }

  T* keep_result() {
    T* result = _ptr;
    _ptr = null;
    return result;
  }

 private:
  T* _ptr;
};

// Each EventSourceManger subclass is a singleton that is used by all processes
// to handle waiting for some OS-level events.  For example on Linux there is
// an EpollEventSource that waits for file descriptor events using epoll.
// Typically an EventSourceManager has/is a thread that it uses to do its
// waiting.  For example on Linux the thread is blocked in epoll_wait().
class EventSource : public EventSourceList::Element {
 public:
  const char* name() { return _name; }

  void register_resource(Resource* resource);
  void unregister_resource(Resource* resource);

  void register_resource_group(ResourceGroup* resource_group);
  void unregister_resource_group(ResourceGroup* resource_group);

  void set_object_notifier(Resource* r, ObjectNotifier* notifier);

  uint32_t read_state(Resource* r);

  void set_state(word id, uint32_t state);
  void set_state(Resource* r, uint32_t state);
  void set_state(const Locker& locker, Resource* r, uint32_t state);

  Mutex* mutex() { return _mutex; }

  bool is_locked();  // For asserts.

  ResourceListFromEventSource& resources() {
    return _resources;
  }

  virtual void use() {}
  virtual void unuse() {}

 protected:
  explicit EventSource(const char* name, int lock_level = 0);
  virtual ~EventSource();

  // Called on a Toit process thread.
  virtual void on_register_resource(Locker& locker, Resource* r) {}
  virtual void on_unregister_resource(Locker& locker, Resource* r) {}

  void unregister_resource(Locker& locker, Resource* resource);

  // Called on the EventSource thread.
  void dispatch(Resource* resource, word data);
  void dispatch(const Locker& locker, Resource* resource, word data);

  // Only for EventSources that use the IntResource subclass.
  IntResource* find_resource_by_id(const Locker& locker, word id);

 private:
  void try_notify(Resource* r, const Locker& locker, bool force = false);

  friend class EventSourceManager;

  Mutex* _mutex;
  ResourceListFromEventSource _resources;
  const char* _name;
};

class LazyEventSource : public EventSource {
 public:
  template<class T>
  static T* get_instance() {
    Locker locker(OS::global_mutex());
    HeapTagScope scope(ITERATE_CUSTOM_TAGS + EVENT_SOURCE_MALLOC_TAG);
    if (!T::_instance) {
      T::_instance = _new T();
      if (!T::_instance) return null;

      if (!T::_instance->start()) {
        delete T::_instance;
        T::_instance = null;
      }
    }
    return T::_instance;
  }

  virtual bool start() = 0;
  virtual void stop() = 0;

  void use() override;
  void unuse() override;

 protected:
  explicit LazyEventSource(const char* name, int lock_level = 0)
    : EventSource(name, lock_level) {}

 private:
  int _usage;
};

class EventSourceManager {
 public:
  ~EventSourceManager() {
    while (EventSource* c = _event_sources.remove_first()) {
      delete c;
    }
  }

  void add_event_source(EventSource* event_source) {
    _event_sources.prepend(event_source);
  }

 private:
  EventSourceList _event_sources;
};

} // namespace toit
