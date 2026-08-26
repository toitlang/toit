// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "../top.h"

#if !defined(TOIT_FREERTOS)

#ifdef TOIT_WINDOWS
#include <io.h>
#include <windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>
#endif

#include "terminal.h"

namespace toit {

static const word TERMINAL_RESIZE_EVENT = 1 << 0;

TerminalResizeEventSource* TerminalResizeEventSource::instance_ = null;

#ifndef TOIT_WINDOWS
static volatile sig_atomic_t terminal_resize_write_fd = -1;
static struct sigaction previous_sigwinch_action;

static void terminal_resize_signal_handler(int signal) {
  USE(signal);
  int saved_errno = errno;
  int fd = terminal_resize_write_fd;
  if (fd >= 0) {
    uint8 marker = 1;
    ssize_t result = write(fd, &marker, sizeof(marker));
    USE(result);
  }
  errno = saved_errno;
}

static bool set_descriptor_flag(int fd, int get_command, int set_command, int flag) {
  int flags = fcntl(fd, get_command);
  return flags >= 0 && fcntl(fd, set_command, flags | flag) == 0;
}
#endif

int read_terminal_dimensions(int fd, TerminalDimensions* dimensions) {
#ifdef TOIT_WINDOWS
  intptr_t os_handle = _get_osfhandle(fd);
  if (os_handle == -1) return ERROR_INVALID_HANDLE;
  HANDLE handle = reinterpret_cast<HANDLE>(os_handle);

  CONSOLE_SCREEN_BUFFER_INFO info;
  if (!GetConsoleScreenBufferInfo(handle, &info)) return GetLastError();
  dimensions->columns = info.srWindow.Right - info.srWindow.Left + 1;
  dimensions->rows = info.srWindow.Bottom - info.srWindow.Top + 1;
  dimensions->pixel_width = 0;
  dimensions->pixel_height = 0;
#else
  winsize size;
  if (ioctl(fd, TIOCGWINSZ, &size) != 0) return errno;
  dimensions->columns = size.ws_col;
  dimensions->rows = size.ws_row;
  dimensions->pixel_width = size.ws_xpixel;
  dimensions->pixel_height = size.ws_ypixel;
#endif
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
#ifdef TOIT_WINDOWS
    , changed_(OS::allocate_condition_variable(mutex()))
#endif
{
  ASSERT(instance_ == null);
  instance_ = this;
}

TerminalResizeEventSource::~TerminalResizeEventSource() {
#ifdef TOIT_WINDOWS
  OS::dispose(changed_);
#endif
  instance_ = null;
}

bool TerminalResizeEventSource::start() {
  stopping_ = false;
#ifdef TOIT_WINDOWS
  return spawn();
#else
  if (pipe(wake_pipe_) != 0) return false;
  if (!set_descriptor_flag(wake_pipe_[0], F_GETFD, F_SETFD, FD_CLOEXEC) ||
      !set_descriptor_flag(wake_pipe_[1], F_GETFD, F_SETFD, FD_CLOEXEC) ||
      !set_descriptor_flag(wake_pipe_[1], F_GETFL, F_SETFL, O_NONBLOCK)) {
    close(wake_pipe_[0]);
    close(wake_pipe_[1]);
    wake_pipe_[0] = wake_pipe_[1] = -1;
    return false;
  }

  struct sigaction action;
  memset(&action, 0, sizeof(action));
  sigemptyset(&action.sa_mask);
  action.sa_handler = terminal_resize_signal_handler;
  action.sa_flags = SA_RESTART;
  if (sigaction(SIGWINCH, &action, &previous_sigwinch_action) != 0) {
    close(wake_pipe_[0]);
    close(wake_pipe_[1]);
    wake_pipe_[0] = wake_pipe_[1] = -1;
    return false;
  }
  terminal_resize_write_fd = wake_pipe_[1];

  if (spawn()) return true;
  terminal_resize_write_fd = -1;
  sigaction(SIGWINCH, &previous_sigwinch_action, null);
  close(wake_pipe_[0]);
  close(wake_pipe_[1]);
  wake_pipe_[0] = wake_pipe_[1] = -1;
  return false;
#endif
}

void TerminalResizeEventSource::stop() {
#ifdef TOIT_WINDOWS
  {
    Locker locker(mutex());
    stopping_ = true;
    OS::signal_all(changed_);
  }
#else
  sigaction(SIGWINCH, &previous_sigwinch_action, null);
  terminal_resize_write_fd = -1;
  {
    Locker locker(mutex());
    stopping_ = true;
  }
  uint8 marker = 1;
  ssize_t result;
  do {
    result = write(wake_pipe_[1], &marker, sizeof(marker));
  } while (result < 0 && errno == EINTR);
#endif
  join();
#ifndef TOIT_WINDOWS
  close(wake_pipe_[0]);
  close(wake_pipe_[1]);
  wake_pipe_[0] = wake_pipe_[1] = -1;
#endif
}

void TerminalResizeEventSource::on_register_resource(
    Locker& locker,
    Resource* resource) {
  USE(locker);
  USE(resource);
#ifdef TOIT_WINDOWS
  OS::signal(changed_);
#endif
}

void TerminalResizeEventSource::on_unregister_resource(
    Locker& locker,
    Resource* resource) {
  USE(locker);
  USE(resource);
#ifdef TOIT_WINDOWS
  OS::signal(changed_);
#endif
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
#ifdef TOIT_WINDOWS
  Locker locker(mutex());
  while (!stopping_) {
    while (!stopping_ && resources().is_empty()) {
      OS::wait(changed_);
    }
    if (stopping_) return;
    // Windows does not deliver console window-size changes as a process
    // signal. Keep the compatibility implementation inside the native event
    // source so Toit applications still receive event-driven notifications.
    OS::wait_us(changed_, 50 * 1000);
    if (!stopping_) dispatch_changes_(locker);
  }
#else
  while (true) {
    uint8 markers[64];
    ssize_t result;
    do {
      result = read(wake_pipe_[0], markers, sizeof(markers));
    } while (result < 0 && errno == EINTR);
    if (result <= 0) return;

    Locker locker(mutex());
    if (stopping_) return;
    dispatch_changes_(locker);
  }
#endif
}

}  // namespace toit

#endif  // !defined(TOIT_FREERTOS)
