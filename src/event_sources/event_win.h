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
};

class WindowsEventThread;
class WindowsResourceEvent;

class WindowsEventSource :  public LazyEventSource {
 public:
  static WindowsEventSource* instance() { return _instance; }

  WindowsEventSource();
  ~WindowsEventSource() override;

  void on_event(WindowsResource* r, HANDLE event);

 protected:
  bool start() override;

  void stop() override;

 private:
  void on_register_resource(Locker& locker, Resource* r) override;
  void on_unregister_resource(Locker& locker, Resource* r) override;

  static WindowsEventSource* _instance;

  std::vector<WindowsEventThread*> _threads;
  std::unordered_multimap<WindowsResource*, WindowsResourceEvent*> _resource_events;
};

}
#endif
