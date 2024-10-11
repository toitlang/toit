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

#include "../resource.h"
#include "../os.h"

namespace toit {

class EpollEventSource : public EventSource, public Thread {
 public:
  static EpollEventSource* instance() {
    if (instance_ == null) {
      instance_ = _new EpollEventSource();
    }
    return instance_;
  }

  EpollEventSource();
  ~EpollEventSource();

  bool is_control_fd(int fd) const {
    return fd == control_read_ || fd == control_write_;
  }

 protected:
  // The default implementation closes the file descriptor.
  virtual void on_removed(int fd);
  // The default implementation uses `find_resource_by_id`, assuming that
  // resources are `IntResource` instances.
  virtual Resource* find_resource_for_fd(Locker& locker, int fd);
  // The default implementation assumes the resource is an `IntResource` and
  // returns its id.
  virtual int fd_for_resource(Resource* resource);

 private:
  virtual void on_register_resource(Locker& locker, Resource* resource) override;
  virtual void on_unregister_resource(Locker& locker, Resource* resource) override;

  void entry() override;

  static EpollEventSource* instance_;

  int epoll_fd_;
  int control_read_;
  int control_write_;
};

} // namespace toit
