// Copyright (C) 2024 Toitware ApS.
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

#ifdef TOIT_LINUX

#include <gpiod.h>

#include "./gpio_linux.h"
#include "../resources/gpio_linux.h"

#include "../objects_inline.h"


namespace toit {

void GpioEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  auto resource = static_cast<GpioPinResource*>(r);
  auto element = _new RequestElement(resource->fd(), resource->request());
  if (element == null) {
    // On Linux this should never happen.
    FATAL("Failed to allocate RequestElement");
  }
  unregistered_requests_list_.append(element);
  EpollEventSourceBase::on_unregister_resource(locker, r);
}

void GpioEventSource::on_removed(int fd) {
  for (auto it : unregistered_requests_list_) {
    if (it->fd == fd) {
      unregistered_requests_list_.remove(it);
      gpiod_line_request_release(it->request);
      return;
    }
  }
}

Resource* GpioEventSource::find_resource_for_fd(Locker& locker, int fd) {
  return find_resource([&](Resource* r) {
    auto resource = static_cast<GpioPinResource*>(r);
    if (resource->fd() == fd) return true;
    return false;
  });
}

int GpioEventSource::fd_for_resource(Resource* r) {
  auto resource = static_cast<GpioPinResource*>(r);
  return resource->fd();
}

} // namespace toit

#endif // TOIT_LINUX
