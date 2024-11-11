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

  int offset() const { return offset_; }

  gpiod_line_settings* settings() const { return settings_; }
  void replace_settings(gpiod_line_settings* settings);

  gpiod_line_request* request() const { return request_; }
  void set_request(gpiod_line_request* request) { request_ = request; }

  Object* apply_and_store_settings(gpiod_line_settings* settings, Process* process);

  void delete_or_mark_for_deletion() override;
  void removed_from_event_source();

  int fd() const {
    ASSERT(fd_ != -1);
    return fd_;
  }
  void set_fd(int fd) {
    ASSERT(fd_ == -1);
    fd_ = fd;
  }

  uint64 last_edge_detection_timestamp() const { return last_edge_detection_timestamp_; }
  void set_last_edge_detection_timestamp(uint64 timestamp) {
    last_edge_detection_timestamp_ = timestamp;
  }

  gpiod_edge_event_buffer* event_buffer() const { return event_buffer_; }
  void set_event_buffer(gpiod_edge_event_buffer* event_buffer) {
    event_buffer_ = event_buffer;
  }

 private:
  static Mutex* mutex_;

  enum TeardownState {
    ALIVE,
    REMOVED,
    DELETED,
  };

  int offset_ = -1;
  int fd_ = -1;
  uint64 last_edge_detection_timestamp_ = 0;
  gpiod_line_settings* settings_ = null;
  gpiod_line_request* request_ = null;
  gpiod_edge_event_buffer* event_buffer_ = null;
  TeardownState teardown_state_ = ALIVE;
};

} // namespace toit

#endif // TOIT_LINUX
