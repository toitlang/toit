// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "../top.h"

#ifdef TOIT_WINDOWS

#include <io.h>
#include <windows.h>

#include "../error_win.h"
#include "../event_sources/terminal_win.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"

namespace toit {

class TerminalModeResource : public Resource {
 public:
  TAG(TerminalModeResource);

  static bool is_claimed(HANDLE handle) {
    for (TerminalModeResource* current = claimed_; current != null; current = current->next_) {
      if (current->handle_ == handle) return true;
    }
    return false;
  }

  TerminalModeResource(ResourceGroup* group, HANDLE handle, DWORD original_mode)
      : Resource(group)
      , handle_(handle)
      , original_mode_(original_mode)
      , next_(claimed_) {
    claimed_ = this;
  }

  ~TerminalModeResource() override {
    Locker locker(OS::global_mutex());
    if (!active_) return;
    SetConsoleMode(handle_, original_mode_);
    release_claim_();
  }

  int restore() {
    Locker locker(OS::global_mutex());
    if (!active_) return 0;
    if (!SetConsoleMode(handle_, original_mode_)) return GetLastError();
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

  HANDLE handle_;
  DWORD original_mode_;
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
  return BOOL(_isatty(fd));
}

PRIMITIVE(enter_raw) {
  ARGS(SimpleResourceGroup, group, int, fd);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  intptr_t os_handle = _get_osfhandle(fd);
  if (os_handle == -1) return windows_error(process, ERROR_INVALID_HANDLE);
  HANDLE handle = reinterpret_cast<HANDLE>(os_handle);

  TerminalModeResource* resource = null;
  DWORD error = ERROR_SUCCESS;
  bool already_in_use = false;
  {
    Locker locker(OS::global_mutex());
    already_in_use = TerminalModeResource::is_claimed(handle);
    if (!already_in_use) {
      DWORD original_mode;
      if (!GetConsoleMode(handle, &original_mode)) {
        error = GetLastError();
      } else {
        DWORD raw_mode = original_mode;
        raw_mode &= ~(ENABLE_ECHO_INPUT |
                      ENABLE_LINE_INPUT |
                      ENABLE_PROCESSED_INPUT |
                      ENABLE_QUICK_EDIT_MODE);
        raw_mode |= ENABLE_EXTENDED_FLAGS | ENABLE_VIRTUAL_TERMINAL_INPUT;
        if (!SetConsoleMode(handle, raw_mode)) {
          error = GetLastError();
        } else {
          resource = _new TerminalModeResource(group, handle, original_mode);
          if (resource == null) SetConsoleMode(handle, original_mode);
        }
      }
    }
  }
  if (already_in_use) FAIL(ALREADY_IN_USE);
  if (error != ERROR_SUCCESS) return windows_error(process, error);
  if (resource == null) FAIL(MALLOC_FAILED);

  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(restore) {
  ARGS(TerminalModeResource, resource, SimpleResourceGroup, group);
  if (resource->resource_group() != group) FAIL(WRONG_OBJECT_TYPE);

  int error = resource->restore();
  if (error != 0) return windows_error(process, error);

  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(size) {
  ARGS(int, fd);

  TerminalDimensions dimensions;
  int error = read_terminal_dimensions(fd, &dimensions);
  if (error != 0) return windows_error(process, error);

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
  if (error != 0) return windows_error(process, error);

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

#endif  // TOIT_WINDOWS
