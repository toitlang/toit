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

#pragma once

#include "./epoll_linux.h"
#include "../os.h"
#include "../resource.h"

namespace toit {

class GpioEventSource : public EpollEventSourceBase {
 public:
  static GpioEventSource* instance() { return instance_; }

  explicit GpioEventSource();
  ~GpioEventSource() override;

 protected:
  void on_register_resource(Locker& locker, Resource* r) override;
  void on_unregister_resource(Locker& locker, Resource* r) override;
  void on_removed(int fd) override;
  Resource* find_resource_for_fd(Locker& locker, int fd) override;
  int fd_for_resource(Resource* r) override;

 private:
  static GpioEventSource* instance_;

  bool started_ = false;
  ResourceListFromEventSource unregistered_resources_;
};

} // namespace toit
