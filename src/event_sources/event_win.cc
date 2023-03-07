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

WindowsEventSource* WindowsEventSource::instance_ = null;

class WindowsEventThread;
class WindowsResourceEvent {
 public:
  WindowsResourceEvent(WindowsResource* resource, HANDLE event, WindowsEventThread* thread)
      : resource_(resource)
      , event_(event)
      , thread_(thread) {}
  WindowsResource* resource() const { return resource_; }
  HANDLE event() const { return event_; }
  WindowsEventThread* thread() const { return thread_; }
  bool is_event_enabled() { return resource_->is_event_enabled(event_); }
 private:
  WindowsResource* resource_;
  HANDLE event_;
  WindowsEventThread* thread_;
};

class WindowsEventThread: public Thread {
 public:
  explicit WindowsEventThread(WindowsEventSource* event_source)
      : Thread("WindowsEventThread")
      , handles_()
      , resources_()
      , count_(1)
      , event_source_(event_source)
      , recalculated_(OS::allocate_condition_variable(event_source->mutex())) {
    control_event_ = CreateEvent(NULL, true, false, NULL);
    handles_[0] = control_event_;
  }

  ~WindowsEventThread() override {
    CloseHandle(control_event_);
  }

  void stop() {
    Locker locker(event_source_->mutex());
    stopped_ = true;
    SetEvent(control_event_);
  }

  size_t size() {
    return resource_events_.size();
  }

  void add_resource_event(Locker& event_source_locker, WindowsResourceEvent* resource_event) {
    ASSERT(resource_events_.size() < MAXIMUM_WAIT_OBJECTS - 2);
    resource_events_.insert(resource_event);
    SetEvent(control_event_); // Recalculate the wait objects.
    OS::wait(recalculated_);
  }

  void remove_resource_event(Locker& event_source_locker, WindowsResourceEvent* resource_event) {
    size_t number_erased = resource_events_.erase(resource_event);
    if (number_erased > 0) {
      SetEvent(control_event_); // Recalculate the wait objects.
      OS::wait(recalculated_);
    }
  }

 protected:
  void entry() override {
    while (true) {
      DWORD result = WaitForMultipleObjects(count_, handles_, false, INFINITE);
      {
        Locker locker(event_source_->mutex());
        if (result == WAIT_OBJECT_0 + 0) {
          if (stopped_) break;
          recalculate_handles();
        } else if (result != WAIT_FAILED) {
          size_t index = result - WAIT_OBJECT_0;
          ResetEvent(handles_[index]);
          if (resources_[index]->is_event_enabled(handles_[index]))
            event_source_->on_event(locker, resources_[index], handles_[index]);
          else
            recalculate_handles();
        } else {
          FATAL("wait failed. error=%lu", GetLastError());
        }
      }
    }
  }

 private:
  void recalculate_handles() {
    int index = 1;
    for (auto resource_event : resource_events_) {
      if (resource_event->is_event_enabled()) {
        handles_[index] = resource_event->event();
        resources_[index] = resource_event->resource();
        index++;
      }
    }
    count_ = index;
    ResetEvent(control_event_);
    OS::signal_all(recalculated_);
  }

  bool stopped_ = false;
  HANDLE control_event_;
  HANDLE handles_[MAXIMUM_WAIT_OBJECTS];
  WindowsResource* resources_[MAXIMUM_WAIT_OBJECTS];
  DWORD count_;
  std::unordered_set<WindowsResourceEvent*> resource_events_;
  WindowsEventSource* event_source_;
  ConditionVariable* recalculated_;
};

WindowsEventSource::WindowsEventSource() : LazyEventSource("WindowsEvents", 1), threads_(), resource_events_() {
  ASSERT(instance_ == null);
  instance_ = this;
}

WindowsEventSource::~WindowsEventSource() {
  for (auto item : resource_events_) {
    delete item.second;
  }
}

void WindowsEventSource::on_register_resource(Locker &locker, Resource* r) {
  auto windows_resource = reinterpret_cast<WindowsResource*>(r);
  for (auto event : windows_resource->events()) {
    WindowsResourceEvent* resource_event;

    // Find a thread with capacity.
    bool placed_it = false;
    for (auto thread : threads_) {
      if (thread->size() < MAXIMUM_WAIT_OBJECTS - 2) {
        resource_event = _new WindowsResourceEvent(windows_resource, event, thread);
        placed_it = true;
        break;
      }
    }

    if (!placed_it) {
      // No worker thread with capacity was found. Spawn a new thread.
      auto thread = _new WindowsEventThread(this);
      threads_.push_back(thread);
      thread->spawn();
      resource_event = _new WindowsResourceEvent(windows_resource, event, thread);
    }

    resource_events_.insert(std::make_pair(windows_resource, resource_event));
    resource_event->thread()->add_resource_event(locker, resource_event);
  }
}

void WindowsEventSource::on_unregister_resource(Locker &locker, Resource* r) {
  auto windows_resource = reinterpret_cast<WindowsResource*>(r);
  auto range = resource_events_.equal_range(windows_resource);
  for (auto it = range.first; it != range.second; ++it) {
    it->second->thread()->remove_resource_event(locker, it->second);
    delete it->second;
  }
  resource_events_.erase(windows_resource);

  windows_resource->do_close();
  // sending an event to let the resource update its state, typically to a CLOSE state.
  dispatch(locker, windows_resource, reinterpret_cast<word>(INVALID_HANDLE_VALUE));
}

void WindowsEventSource::on_event(Locker& locker, WindowsResource* r, HANDLE event) {
   word data = reinterpret_cast<word>(event);
   dispatch(locker, r, data);
}

bool WindowsEventSource::start() {
  WSADATA wsa_data;
  int winsock_startup_result = WSAStartup(MAKEWORD(2,2), &wsa_data);
  return winsock_startup_result == NO_ERROR;
}

void WindowsEventSource::stop() {
  for (auto thread : threads_) {
    thread->stop();
    thread->join();
    delete thread;
  }

  WSACleanup();
}

} // namespace toit
#endif // TOIT_WINDOWS
