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

GpioEventSource* GpioEventSource::instance_ = null;

GpioEventSource::GpioEventSource() : EpollEventSourceBase("Gpio") {
  ASSERT(instance_ == null);
  instance_ = this;
}
GpioEventSource::~GpioEventSource() {
  ASSERT(unregistered_resources_.is_empty());
  if (started_) stop();
  instance_ = null;
}

void GpioEventSource::on_register_resource(Locker& locker, Resource* r) {
  if (!started_) {
    started_ = true;
    if (!start()) {
      FATAL("Failed to start GpioEventSource");
    }
  }
  EpollEventSourceBase::on_register_resource(locker, r);
}

void GpioEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  // At this point the resource is already unlinked from the event-source's
  // resource list.
  ASSERT(!is_linked_resource(r));
  // Link it into the unregistered list. This way the gpio-thread can find
  // the resource when it is removed.
  unregistered_resources_.append(r);
  EpollEventSourceBase::on_unregister_resource(locker, r);
}

void GpioEventSource::on_removed(int fd) {
  Locker locker(mutex());
  for (auto it : unregistered_resources_) {
    auto resource = static_cast<GpioPinResource*>(it);
    if (resource->fd() == fd) {
      unregistered_resources_.unlink(it);
      resource->removed_from_event_source();
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
