// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "../top.h"

#if !defined(TOIT_FREERTOS)

#ifdef TOIT_WINDOWS
#include <io.h>
#include <windows.h>

#include "../error_win.h"
#else
#include <errno.h>
#include <termios.h>
#include <unistd.h>
#endif

#include "../event_sources/terminal.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"

namespace toit {

class TerminalModeResource : public Resource {
 public:
  TAG(TerminalModeResource);

#ifdef TOIT_WINDOWS
  TerminalModeResource(ResourceGroup* group, HANDLE handle, DWORD original_mode)
      : Resource(group)
      , handle_(handle)
      , original_mode_(original_mode)
      , active_(true) {}
#else
  TerminalModeResource(ResourceGroup* group, int fd, const termios& original_mode)
      : Resource(group)
      , fd_(fd)
      , original_mode_(original_mode)
      , active_(true) {}
#endif

  ~TerminalModeResource() override { restore(); }

  int restore() {
    if (!active_) return 0;
#ifdef TOIT_WINDOWS
    if (!SetConsoleMode(handle_, original_mode_)) return GetLastError();
#else
    if (tcsetattr(fd_, TCSAFLUSH, &original_mode_) != 0) return errno;
#endif
    active_ = false;
    return 0;
  }

 private:
#ifdef TOIT_WINDOWS
  HANDLE handle_;
  DWORD original_mode_;
#else
  int fd_;
  termios original_mode_;
#endif
  bool active_;
};

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

#ifdef TOIT_WINDOWS
  return _isatty(fd) ? process->true_object() : process->false_object();
#else
  return isatty(fd) ? process->true_object() : process->false_object();
#endif
}

PRIMITIVE(enter_raw) {
  ARGS(SimpleResourceGroup, group, int, fd);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

#ifdef TOIT_WINDOWS
  intptr_t os_handle = _get_osfhandle(fd);
  if (os_handle == -1) return windows_error(process, ERROR_INVALID_HANDLE);
  HANDLE handle = reinterpret_cast<HANDLE>(os_handle);

  DWORD original_mode;
  if (!GetConsoleMode(handle, &original_mode)) return windows_error(process);

  DWORD raw_mode = original_mode;
  raw_mode &= ~(ENABLE_ECHO_INPUT |
                ENABLE_LINE_INPUT |
                ENABLE_PROCESSED_INPUT |
                ENABLE_QUICK_EDIT_MODE);
  raw_mode |= ENABLE_EXTENDED_FLAGS | ENABLE_VIRTUAL_TERMINAL_INPUT;
  if (!SetConsoleMode(handle, raw_mode)) return windows_error(process);

  auto resource = _new TerminalModeResource(group, handle, original_mode);
  if (resource == null) {
    SetConsoleMode(handle, original_mode);
    FAIL(MALLOC_FAILED);
  }
#else
  termios original_mode;
  if (tcgetattr(fd, &original_mode) != 0) return Primitive::os_error(errno, process);

  termios raw_mode = original_mode;
  cfmakeraw(&raw_mode);
  if (tcsetattr(fd, TCSAFLUSH, &raw_mode) != 0) return Primitive::os_error(errno, process);

  auto resource = _new TerminalModeResource(group, fd, original_mode);
  if (resource == null) {
    tcsetattr(fd, TCSAFLUSH, &original_mode);
    FAIL(MALLOC_FAILED);
  }
#endif

  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(restore) {
  ARGS(TerminalModeResource, resource, SimpleResourceGroup, group);
  if (resource->resource_group() != group) FAIL(WRONG_OBJECT_TYPE);

  int error = resource->restore();
  if (error != 0) {
#ifdef TOIT_WINDOWS
    return windows_error(process, error);
#else
    return Primitive::os_error(error, process);
#endif
  }

  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(size) {
  ARGS(int, fd);

  TerminalDimensions dimensions;
  int error = read_terminal_dimensions(fd, &dimensions);
  if (error != 0) {
#ifdef TOIT_WINDOWS
    return windows_error(process, error);
#else
    return Primitive::os_error(error, process);
#endif
  }

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
  if (error != 0) {
#ifdef TOIT_WINDOWS
    return windows_error(process, error);
#else
    return Primitive::os_error(error, process);
#endif
  }

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

#else

#include "../primitive.h"

namespace toit {

MODULE_IMPLEMENTATION(terminal, MODULE_TERMINAL)

PRIMITIVE(init) { FAIL(UNSUPPORTED); }
PRIMITIVE(is_terminal) { FAIL(UNSUPPORTED); }
PRIMITIVE(enter_raw) { FAIL(UNSUPPORTED); }
PRIMITIVE(restore) { FAIL(UNSUPPORTED); }
PRIMITIVE(size) { FAIL(UNSUPPORTED); }
PRIMITIVE(resize_init) { FAIL(UNSUPPORTED); }
PRIMITIVE(resize_watch) { FAIL(UNSUPPORTED); }
PRIMITIVE(resize_unwatch) { FAIL(UNSUPPORTED); }

}  // namespace toit

#endif
