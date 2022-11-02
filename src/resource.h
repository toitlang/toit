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
    : resource_group_(resource_group)
    , state_(0)
    , object_notifier_(null) {
  }

  virtual ~Resource();

  template<typename T>
  T as() { return static_cast<T>(this); }

  ResourceGroup* resource_group() const { return resource_group_; }

  uint32_t state() const { return state_; }
  void set_state(uint32_t state) { state_ = state; }

  ObjectNotifier* object_notifier() const { return object_notifier_; }
  void set_object_notifier(ObjectNotifier* object_notifier) { object_notifier_ = object_notifier; }

  // When a resource group is torn down we call this.  Normally it deletes it, but
  // it may just mark it for deletion in case there are still other references to it,
  // eg from callbacks at the OS level.
  virtual void make_deletable() {
    delete this;
  }

 private:
  ResourceGroup* resource_group_;
  uint32_t state_;

  // The object_notifier is manipulated under the EventSource lock.
  ObjectNotifier* object_notifier_;
};

class IntResource : public Resource {
 public:
  TAG(IntResource);
  IntResource(ResourceGroup* group, word id)
    : Resource(group)
    , id_(id) {}

  word id() { return id_; }

 private:
  word id_;
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

  Process* process() { return process_; }

  EventSource* event_source() { return event_source_; }

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
  void operator delete(void* ptr) {
    ::operator delete(ptr);
  }

  ResourceList& resources() { return resources_; }

 private:
  Process* const process_;
  EventSource* event_source_;
  ResourceList resources_;

  friend class EventSource;
};
typedef LinkedList<EventSource> EventSourceList;

template <typename Resource>
class AutoUnregisteringResource {
 public:
  AutoUnregisteringResource(ResourceGroup* group, Resource* resource) : group_(group), resource_(resource) {}

  ~AutoUnregisteringResource() {
    if (resource_) {
      group_->unregister_resource(resource_);
    }
  }

  void set_external_address(ByteArray* proxy) {
    proxy->set_external_address(resource_);
    resource_ = null;
  }

 private:
  ResourceGroup* group_;
  Resource* resource_;
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
      : ptr_(ptr) {
    SimpleResource* this_class_is_for_subclasses_of_simple_resource = ptr;
    USE(this_class_is_for_subclasses_of_simple_resource);
  }

  ~SimpleResourceAllocationManager() {
    if (ptr_) {
      ptr_->resource_group()->unregister_resource(ptr_);
      ptr_ = null;
    }
  }

  T* keep_result() {
    T* result = ptr_;
    ptr_ = null;
    return result;
  }

 private:
  T* ptr_;
};

// Each EventSourceManger subclass is a singleton that is used by all processes
// to handle waiting for some OS-level events.  For example on Linux there is
// an EpollEventSource that waits for file descriptor events using epoll.
// Typically an EventSourceManager has/is a thread that it uses to do its
// waiting.  For example on Linux the thread is blocked in epoll_wait().
class EventSource : public EventSourceList::Element {
 public:
  const char* name() { return name_; }

  void register_resource(Resource* resource);
  void unregister_resource(Resource* resource);

  void register_resource_group(ResourceGroup* resource_group);
  virtual void unregister_resource_group(ResourceGroup* resource_group);

  bool update_resource_monitor(Resource* r, Process* process, Object* monitor);
  void delete_resource_monitor(Resource* r);

  uint32_t read_state(Resource* r);

  void set_state(word id, uint32_t state);
  void set_state(Resource* r, uint32_t state);
  void set_state(const Locker& locker, Resource* r, uint32_t state);

  Mutex* mutex() { return mutex_; }

  bool is_locked();  // For asserts.

  ResourceListFromEventSource& resources() {
    return resources_;
  }

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

  Mutex* mutex_;
  ResourceListFromEventSource resources_;
  const char* name_;
};

class LazyEventSource : public EventSource {
 public:
  LazyEventSource(const char* name, int lock_level = 0)
    : EventSource(name, lock_level) {
  }

  // Overridden to automatically call unuse().
  void unregister_resource_group(ResourceGroup* resource_group) override;

  // The use() and unuse() methods are exposed, so we can get errors out of the
  // call to use() and fail in a reasonable way. The alternative would have been
  // to automatically call use() when registering a resource group - to match
  // how unuse() is automatically called when unregistering - but because the
  // registering is done from a call to the ResourceGroup constructor, it is hard
  // to get any errors out.
  bool use();
  void unuse();

 protected:
  virtual bool start() = 0;
  virtual void stop() = 0;

 private:
  int usage_ = 0;
};

class EventSourceManager {
 public:
  ~EventSourceManager() {
    while (EventSource* c = event_sources_.remove_first()) {
      delete c;
    }
  }

  void add_event_source(EventSource* event_source) {
    event_sources_.prepend(event_source);
  }

 private:
  EventSourceList event_sources_;
};

} // namespace toit
