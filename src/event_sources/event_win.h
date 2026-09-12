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

#pragma once

#include "../top.h"

#if defined(TOIT_WINDOWS)
#include "../resource.h"
#include "../os.h"
#include "windows.h"
#include <queue>
#include <unordered_map>

namespace toit {

class WindowsResource : public Resource {
 public:
  explicit WindowsResource(ResourceGroup* resource_group) : Resource(resource_group) {}
  virtual std::vector<HANDLE> events() = 0;
  virtual uint32_t on_event(HANDLE event, uint32_t state) = 0;
  virtual void do_close() = 0;
  virtual bool is_event_enabled(HANDLE event) { return true; }
};

// An OVERLAPPED structure, and whether the last operation issued with it was
// started.
//
// Closing a handle cancels its pending operations, but their completion can
// still be written to the OVERLAPPED structure after the close returns. Call
// cancel_and_wait before closing the handle or the event, and before freeing
// the structure.
class WindowsOverlapped {
 public:
  OVERLAPPED* get() { return &overlapped_; }
  HANDLE event() const { return overlapped_.hEvent; }
  void set_event(HANDLE event) { overlapped_.hEvent = event; }

  // Records the result of an overlapped call, like ReadFile or WSARecv.
  // Returns whether the operation started, which includes completing
  // synchronously. Doesn't change the last error.
  bool issued(bool success, DWORD error) {
    started_ = success || error == ERROR_IO_PENDING;
    return started_;
  }

  // Cancels the last operation and waits for it to complete, unless it failed
  // to start: the structure isn't meaningful after a synchronous failure, and
  // waiting could block forever.
  void cancel_and_wait(HANDLE handle);

 private:
  OVERLAPPED overlapped_{};
  bool started_ = false;
};

class WindowsEventThread;
class WindowsResourceEvent;

class WindowsEventSource :  public LazyEventSource {
 public:
  static WindowsEventSource* instance() { return instance_; }

  WindowsEventSource();
  ~WindowsEventSource() override;

  void on_event(Locker& locker, WindowsResource* r, HANDLE event);

 protected:
  bool start() override;

  void stop() override;

 private:
  void on_register_resource(Locker& locker, Resource* r) override;
  void on_unregister_resource(Locker& locker, Resource* r) override;

  static WindowsEventSource* instance_;

  std::vector<WindowsEventThread*> threads_;
  std::unordered_multimap<WindowsResource*, WindowsResourceEvent*> resource_events_;
};

}
#endif
