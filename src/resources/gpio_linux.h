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

#include "../top.h"

#ifdef TOIT_LINUX

#include "../resource.h"

struct gpiod_line_settings;
struct gpiod_line_request;

namespace toit {

class GpioPinResource : public Resource {
 public:
  TAG(GpioPinResource);
  GpioPinResource(ResourceGroup* group, int offset)
      : Resource(group)
      , offset_(offset){}

  ~GpioPinResource() override;

  int offset() { return offset_; }

  gpiod_line_settings* settings() { return settings_; }
  void replace_settings(gpiod_line_settings* settings);

  gpiod_line_request* request() { return request_; }
  void set_request(gpiod_line_request* request) { request_ = request; }

  Object* apply_and_store_settings(gpiod_line_settings* settings, Process* process);

  int fd() const {
    ASSERT(fd_ != -1);
    return fd_;
  }
  void set_fd(int fd) {
    ASSERT(fd_ == -1);
    fd_ = fd;
  }

 private:
  int offset_ = -1;
  int fd_ = -1;
  gpiod_line_settings* settings_ = null;
  gpiod_line_request* request_ = null;
};

} // namespace toit

#endif // TOIT_LINUX
