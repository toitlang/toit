// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "../top.h"

#ifdef TOIT_POSIX

#include <errno.h>
#include <termios.h>
#include <unistd.h>

#include "../event_sources/terminal_posix.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"

namespace toit {

class TerminalModeResource : public Resource {
 public:
  TAG(TerminalModeResource);

  static bool is_claimed(int fd) {
    for (TerminalModeResource* current = claimed_; current != null; current = current->next_) {
      if (current->fd_ == fd) return true;
    }
    return false;
  }

  TerminalModeResource(ResourceGroup* group, int fd, const termios& original_mode)
      : Resource(group)
      , fd_(fd)
      , original_mode_(original_mode)
      , next_(claimed_) {
    claimed_ = this;
  }

  ~TerminalModeResource() override {
    Locker locker(OS::global_mutex());
    if (!active_) return;
    tcsetattr(fd_, TCSAFLUSH, &original_mode_);
    release_claim_();
  }

  int restore() {
    Locker locker(OS::global_mutex());
    if (!active_) return 0;
    if (tcsetattr(fd_, TCSAFLUSH, &original_mode_) != 0) return errno;
    release_claim_();
    return 0;
  }

 private:
  void release_claim_() {
    TerminalModeResource** link = &claimed_;
    while (*link != this) {
      ASSERT(*link != null);
      link = &(*link)->next_;
    }
    *link = next_;
    active_ = false;
  }

  static TerminalModeResource* claimed_;

  int fd_;
  termios original_mode_;
  TerminalModeResource* next_;
  bool active_ = true;
};

TerminalModeResource* TerminalModeResource::claimed_ = null;

class TerminalResizeResourceGroup : public ResourceGroup {
 public:
  TAG(TerminalResizeResourceGroup);

  TerminalResizeResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    USE(resource);
    return state | static_cast<uint32_t>(data);
  }
};

MODULE_IMPLEMENTATION(terminal, MODULE_TERMINAL)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto group = _new SimpleResourceGroup(process);
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(is_terminal) {
  ARGS(int, fd);
  return BOOL(isatty(fd));
}

PRIMITIVE(enter_raw) {
  ARGS(SimpleResourceGroup, group, int, fd);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  TerminalModeResource* resource = null;
  int error = 0;
  bool already_in_use = false;
  {
    Locker locker(OS::global_mutex());
    already_in_use = TerminalModeResource::is_claimed(fd);
    if (!already_in_use) {
      termios original_mode;
      if (tcgetattr(fd, &original_mode) != 0) {
        error = errno;
      } else {
        termios raw_mode = original_mode;
        cfmakeraw(&raw_mode);
        if (tcsetattr(fd, TCSAFLUSH, &raw_mode) != 0) {
          error = errno;
        } else {
          resource = _new TerminalModeResource(group, fd, original_mode);
          if (resource == null) tcsetattr(fd, TCSAFLUSH, &original_mode);
        }
      }
    }
  }
  if (already_in_use) FAIL(ALREADY_IN_USE);
  if (error != 0) return Primitive::os_error(error, process);
  if (resource == null) FAIL(MALLOC_FAILED);

  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(restore) {
  ARGS(TerminalModeResource, resource, SimpleResourceGroup, group);
  if (resource->resource_group() != group) FAIL(WRONG_OBJECT_TYPE);

  int error = resource->restore();
  if (error != 0) return Primitive::os_error(error, process);

  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(size) {
  ARGS(int, fd);

  TerminalDimensions dimensions;
  int error = read_terminal_dimensions(fd, &dimensions);
  if (error != 0) return Primitive::os_error(error, process);

  Array* result = process->object_heap()->allocate_array(4, Smi::zero());
  if (result == null) FAIL(ALLOCATION_FAILED);
  result->at_put(0, Smi::from(dimensions.columns));
  result->at_put(1, Smi::from(dimensions.rows));
  result->at_put(2, Smi::from(dimensions.pixel_width));
  result->at_put(3, Smi::from(dimensions.pixel_height));
  return result;
}

PRIMITIVE(resize_init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  TerminalResizeEventSource* event_source = TerminalResizeEventSource::instance();
  if (!event_source->use()) FAIL(ERROR);

  auto group = _new TerminalResizeResourceGroup(process, event_source);
  if (group == null) {
    event_source->unuse();
    FAIL(MALLOC_FAILED);
  }

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(resize_watch) {
  ARGS(TerminalResizeResourceGroup, group, int, fd);

  TerminalDimensions dimensions;
  int error = read_terminal_dimensions(fd, &dimensions);
  if (error != 0) return Primitive::os_error(error, process);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto resource = _new TerminalResizeResource(group, fd, dimensions);
  if (resource == null) FAIL(MALLOC_FAILED);
  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(resize_unwatch) {
  ARGS(
      TerminalResizeResource,
      resource,
      TerminalResizeResourceGroup,
      group);
  if (resource->resource_group() != group) FAIL(WRONG_OBJECT_TYPE);

  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

}  // namespace toit

#endif  // TOIT_POSIX
