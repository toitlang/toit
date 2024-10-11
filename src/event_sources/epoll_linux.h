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

class EpollEventSourceBase : public EventSource, public Thread {
 public:
  bool is_control_fd(int fd) const {
    return fd == control_read_ || fd == control_write_;
  }

 protected:
  EpollEventSourceBase(const char* name) : EventSource(name), Thread(name){}
  virtual ~EpollEventSourceBase(){}

  /// Called when the file descriptor was removed from the epoll.
  /// This happens during unregistering of the resource, and is a good
  /// time to close the file descriptor and release any associated resources.
  virtual void on_removed(int fd) = 0;
  /// Finds the resource object for the given file descriptor.
  virtual Resource* find_resource_for_fd(Locker& locker, int fd) = 0;
  /// Returns the file descriptor for the given resource.
  virtual int fd_for_resource(Resource* resource) = 0;

  virtual void on_register_resource(Locker& locker, Resource* resource) override;
  virtual void on_unregister_resource(Locker& locker, Resource* resource) override;

  bool start();
  void stop();

 private:
  void entry() override;

  int epoll_fd_;
  int control_read_;
  int control_write_;
};

class EpollEventSource : public EpollEventSourceBase {
 public:
  static EpollEventSource* instance() { return instance_; }

  EpollEventSource();
  ~EpollEventSource() override;

 protected:
  /// Closes the file descriptor.
  void on_removed(int fd) override;
  /// Uses `find_resource_by_id`, assuming that resources are `IntResource` instances.
  Resource* find_resource_for_fd(Locker& locker, int fd) override;
  /// Returns the id of the resource. Assumes that the resource is an `IntResource`.
  int fd_for_resource(Resource* resource) override;

 private:
  static EpollEventSource* instance_;
};

} // namespace toit
