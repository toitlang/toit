// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "../top.h"

#ifdef TOIT_WINDOWS

#include <io.h>
#include <windows.h>

#include "terminal_win.h"

namespace toit {

static const word TERMINAL_RESIZE_EVENT = 1 << 0;

TerminalResizeEventSource* TerminalResizeEventSource::instance_ = null;

HANDLE terminal_handle(int fd) {
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

bool TerminalResizeResource::refresh() {
  TerminalDimensions dimensions;
  if (read_terminal_dimensions(fd_, &dimensions) != 0) return false;
  if (!(dimensions != dimensions_)) return false;
  dimensions_ = dimensions;
  return true;
}

TerminalResizeEventSource::TerminalResizeEventSource()
    : LazyEventSource("TerminalResize", 1)
    , Thread("TerminalResize")
    , changed_(OS::allocate_condition_variable(mutex())) {
  ASSERT(instance_ == null);
  instance_ = this;
}

TerminalResizeEventSource::~TerminalResizeEventSource() {
  OS::dispose(changed_);
  instance_ = null;
}

bool TerminalResizeEventSource::start() {
  stopping_ = false;
  return spawn();
}

void TerminalResizeEventSource::stop() {
  {
    Locker locker(mutex());
    stopping_ = true;
    OS::signal_all(changed_);
  }
  join();
}

void TerminalResizeEventSource::on_register_resource(
    Locker& locker,
    Resource* resource) {
  USE(locker);
  USE(resource);
  OS::signal(changed_);
}

void TerminalResizeEventSource::on_unregister_resource(
    Locker& locker,
    Resource* resource) {
  USE(locker);
  USE(resource);
  OS::signal(changed_);
}

void TerminalResizeEventSource::dispatch_changes_(Locker& locker) {
  for (auto resource : resources()) {
    auto resize_resource = static_cast<TerminalResizeResource*>(resource);
    if (resize_resource->refresh()) {
      dispatch(locker, resize_resource, TERMINAL_RESIZE_EVENT);
    }
  }
}

void TerminalResizeEventSource::entry() {
  Locker locker(mutex());
  while (!stopping_) {
    while (!stopping_ && resources().is_empty()) {
      OS::wait(changed_);
    }
    if (stopping_) return;

    // Windows reports resize records through the console input buffer. Reading
    // those records here would race with the stdin event source and could
    // consume keyboard input. A timed wait keeps this compatibility path
    // isolated and blocks the thread between checks.
    OS::wait_us(changed_, 50 * 1000);
    if (!stopping_) dispatch_changes_(locker);
  }
}

}  // namespace toit

#endif  // TOIT_WINDOWS
