// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "../top.h"

#ifdef TOIT_WINDOWS

#include <io.h>
#include <windows.h>

#include "../error_win.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "terminal.h"

namespace toit {

static const int TERMINAL_MODE_TOKEN = 0;
static ResourcePool<int, -1> terminal_mode_pool(TERMINAL_MODE_TOKEN);

class TerminalModeResource : public Resource {
 public:
  TAG(TerminalModeResource);

  TerminalModeResource(ResourceGroup* group, HANDLE handle, DWORD original_mode)
      : Resource(group)
      , handle_(handle)
      , original_mode_(original_mode) {}

  ~TerminalModeResource() override {
    if (!active_) return;
    SetConsoleMode(handle_, original_mode_);
    release_();
  }

  int restore() {
    if (!active_) return 0;
    if (!SetConsoleMode(handle_, original_mode_)) return GetLastError();
    release_();
    return 0;
  }

 private:
  void release_() {
    terminal_mode_pool.put(TERMINAL_MODE_TOKEN);
    active_ = false;
  }

  HANDLE handle_;
  DWORD original_mode_;
  bool active_ = true;
};

// Resolves the standard descriptor numbers through the Win32 standard-handle
// table. This is required for pseudoconsoles, whose handles aren't necessarily
// mirrored in the C runtime descriptor table.
static HANDLE terminal_handle(int fd) {
  switch (fd) {
    case 0: return GetStdHandle(STD_INPUT_HANDLE);
    case 1: return GetStdHandle(STD_OUTPUT_HANDLE);
    case 2: return GetStdHandle(STD_ERROR_HANDLE);
  }

  intptr_t os_handle = _get_osfhandle(fd);
  if (os_handle == -1 || os_handle == -2) return INVALID_HANDLE_VALUE;
  return reinterpret_cast<HANDLE>(os_handle);
}

int read_terminal_dimensions(int fd, TerminalDimensions* dimensions) {
  HANDLE handle = terminal_handle(fd);
  if (handle == NULL || handle == INVALID_HANDLE_VALUE) return ERROR_INVALID_HANDLE;

  CONSOLE_SCREEN_BUFFER_INFO info;
  if (!GetConsoleScreenBufferInfo(handle, &info)) return GetLastError();
  dimensions->columns = info.srWindow.Right - info.srWindow.Left + 1;
  dimensions->rows = info.srWindow.Bottom - info.srWindow.Top + 1;
  dimensions->pixel_width = 0;
  dimensions->pixel_height = 0;
  return 0;
}

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

  HANDLE handle = terminal_handle(fd);
  DWORD mode;
  return BOOL(
      handle != NULL &&
      handle != INVALID_HANDLE_VALUE &&
      GetConsoleMode(handle, &mode));
}

PRIMITIVE(enter_raw) {
  ARGS(SimpleResourceGroup, group, int, fd);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  HANDLE handle = terminal_handle(fd);
  if (handle == NULL || handle == INVALID_HANDLE_VALUE) {
    return windows_error(process, ERROR_INVALID_HANDLE);
  }

  if (!terminal_mode_pool.take(TERMINAL_MODE_TOKEN)) FAIL(ALREADY_IN_USE);
  bool handed_to_resource = false;
  Defer release_token { [&] {
    if (!handed_to_resource) terminal_mode_pool.put(TERMINAL_MODE_TOKEN);
  } };

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
  handed_to_resource = true;

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

}  // namespace toit

#endif  // TOIT_WINDOWS
