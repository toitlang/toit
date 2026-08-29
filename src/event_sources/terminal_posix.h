// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#pragma once

#include "../top.h"

#ifdef TOIT_POSIX

#include "../os.h"
#include "../resource.h"

namespace toit {

struct TerminalDimensions {
  int columns;
  int rows;
  int pixel_width;
  int pixel_height;

  bool operator!=(const TerminalDimensions& other) const {
    return columns != other.columns ||
        rows != other.rows ||
        pixel_width != other.pixel_width ||
        pixel_height != other.pixel_height;
  }
};

// Returns zero on success and an OS error code otherwise.
int read_terminal_dimensions(int fd, TerminalDimensions* dimensions);

class TerminalResizeResource : public Resource {
 public:
  TAG(TerminalResizeResource);

  TerminalResizeResource(
      ResourceGroup* group,
      int fd,
      const TerminalDimensions& dimensions)
      : Resource(group)
      , fd_(fd)
      , dimensions_(dimensions) {}

  // Called with the TerminalResizeEventSource lock held.
  bool refresh();

 private:
  int fd_;
  TerminalDimensions dimensions_;
};

class TerminalResizeEventSource : public LazyEventSource, public Thread {
 public:
  static TerminalResizeEventSource* instance() { return instance_; }

  TerminalResizeEventSource();
  ~TerminalResizeEventSource() override;

 protected:
  bool start() override;
  void stop() override;

 private:
  void entry() override;
  void dispatch_changes_(Locker& locker);

  static TerminalResizeEventSource* instance_;

  int wake_pipe_[2] = { -1, -1 };
  bool stopping_ = false;
};

}  // namespace toit

#endif  // TOIT_POSIX
