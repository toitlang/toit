// Copyright (C) 2022 Toitware ApS.
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

#if defined(TOIT_WINDOWS)

#include "event_win.h"
#include <windows.h>
#include <unordered_set>

namespace toit {

WindowsEventSource* WindowsEventSource::_instance = null;

class WindowsEventThread;
class WindowsResourceEvent {
 public:
  WindowsResourceEvent(WindowsResource* resource, HANDLE event, WindowsEventThread* thread)
    : _resource(resource)
    , _event(event)
    , _thread(thread) {}
  WindowsResource* resource() const { return _resource; }
  HANDLE event() const { return _event; }
  WindowsEventThread* thread() const { return _thread; }
 private:
  WindowsResource* _resource;
  HANDLE _event;
  WindowsEventThread* _thread;
};

class WindowsEventThread: public Thread {
 public:
  explicit WindowsEventThread(WindowsEventSource* event_source)
    : Thread("WindowsEventThread")
    , _handles()
    , _resources()
    , _count(1)
    , _event_source(event_source)
    , _mutex(OS::allocate_mutex(1, "WindowsOverlapped" )){
    _control_event = CreateEvent(NULL, true, false, NULL);
    //printf("control_event=%llx\n", (unsigned long long)_control_event);

    _handles[0] = _control_event;
  }

  ~WindowsEventThread() override {
    CloseHandle(_control_event);
  }

  void stop() {
    Locker locker(_mutex);
    _stopped = true;
    SetEvent(_control_event);
  }
  
  size_t size() {
    return _resource_events.size();
  }
  
  void add_resource_event(WindowsResourceEvent* resource_event) {
    ASSERT(_resource_events.size() < MAXIMUM_WAIT_OBJECTS - 2);
    Locker locker(_mutex);
    _resource_events.insert(resource_event);
    SetEvent(_control_event); // Recalculate the wait objects
  }

  void remove_resource_event(WindowsResourceEvent* resource_event) {
    Locker locker(_mutex);
    size_t number_erased = _resource_events.erase(resource_event);
    if (number_erased > 0)
      SetEvent(_control_event); // Recalculate the wait objects
  }

 protected:
  void entry() override {
    while (true) {
      DWORD result = WaitForMultipleObjects(_count, _handles, false, INFINITE);
      if (result == WAIT_OBJECT_0 + 0) {
        if (_stopped) break;
        Locker locker(_mutex);
        // Handles should be recalculated
        recalculate_handles();
        ResetEvent(_control_event);
      } else if (result != WAIT_FAILED){
        size_t index = result - WAIT_OBJECT_0;
//        printf("Notification on %llx\n", (unsigned long long)_handles[index]);
        _event_source->on_event(_resources[index], _handles[index]);
        ResetEvent(_handles[index]);
      }
    }
  }

 private:
  void recalculate_handles() {
    _count = _resource_events.size() + 1;
    int index = 1;
    for (auto resource_event : _resource_events) {
//      printf("handle[%d]=%llx\n", index, (unsigned long long)resource_event->event());
      _handles[index] = resource_event->event();
      _resources[index] = resource_event->resource();
      index++;
    }
  }

  bool _stopped = false;
  HANDLE _control_event;
  HANDLE _handles[MAXIMUM_WAIT_OBJECTS];
  WindowsResource* _resources[MAXIMUM_WAIT_OBJECTS];
  DWORD _count;
  std::unordered_set<WindowsResourceEvent*> _resource_events;
  WindowsEventSource* _event_source;
  Mutex* _mutex;
};

WindowsEventSource::WindowsEventSource() : LazyEventSource("WindowsEvents"), _threads(), _resource_events() {
  ASSERT(_instance == null);

  _instance = this;
}

WindowsEventSource::~WindowsEventSource() {
  for (auto thread : _threads) {
    thread->stop();
    thread->join();
    delete thread;
  }

  for (auto item : _resource_events) {
    delete item.second;
  }

  WSACleanup();
}

void WindowsEventSource::on_register_resource(Locker &locker, Resource* r) {
  AllowThrowingNew host_only;

  auto windows_resource = reinterpret_cast<WindowsResource*>(r);
  for (auto event : windows_resource->events()) {
    WindowsResourceEvent* resource_event;

    // Find a thread with capacity
    bool placed_it = false;
    for(auto thread : _threads) {
      if (thread->size() < MAXIMUM_WAIT_OBJECTS - 2) {
        resource_event = _new WindowsResourceEvent(windows_resource, event, thread);
        thread->add_resource_event(resource_event);
        placed_it = true;
        break;
      }
    }
    if (!placed_it) {
      // Spawn a new thread
      auto thread = _new WindowsEventThread(this);
      _threads.push_back(thread);
      resource_event = _new WindowsResourceEvent(windows_resource, event, thread);
      thread->add_resource_event(resource_event);
      thread->spawn();
    }

    _resource_events.insert(std::make_pair(windows_resource, resource_event));
  }
}

void WindowsEventSource::on_unregister_resource(Locker &locker, Resource* r) {
  AllowThrowingNew host_only;

  auto windows_resource = reinterpret_cast<WindowsResource*>(r);
  auto range = _resource_events.equal_range(windows_resource);
  for (auto it = range.first; it != range.second; ++it) {
    it->second->thread()->remove_resource_event(it->second);
    delete it->second;
  }
  windows_resource->do_close();
  // sending an event to let the resource update is state, typically to a CLOSE state
  dispatch(locker, windows_resource, reinterpret_cast<word>(INVALID_HANDLE_VALUE));
}

void WindowsEventSource::on_event(WindowsResource* r, HANDLE event) {
//  printf("event_source.on_event r=%llx, event=%llx\n", (word)r,(word)event);
  dispatch(r, reinterpret_cast<word>(event));
}

bool WindowsEventSource::start() {
  WSADATA wsa_data;
  int winsock_startup_result = WSAStartup(MAKEWORD(2,2), &wsa_data);
  return winsock_startup_result == NO_ERROR;
}

void WindowsEventSource::stop() {
  WSACleanup();
}

}
#endif // TOIT_WINDOWS
