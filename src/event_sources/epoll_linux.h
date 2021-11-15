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
  static EpollEventSource* instance() { return _instance; }

  EpollEventSource();
  ~EpollEventSource();

  bool is_control_fd(int fd) const {
    return fd == _control_read || fd == _control_write;
  }

 private:
  virtual void on_register_resource(Locker& locker, Resource* r) override;
  virtual void on_unregister_resource(Locker& locker, Resource* r) override;

  void entry() override;

  static EpollEventSource* _instance;

  int _epoll_fd;
  int _control_read;
  int _control_write;
};

} // namespace toit
