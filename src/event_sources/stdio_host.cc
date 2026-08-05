// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "../top.h"

#if !defined(TOIT_FREERTOS)

#ifdef TOIT_WINDOWS
#include <windows.h>
#else
#include <errno.h>
#include <poll.h>
#include <unistd.h>
#endif

#include "stdio_host.h"

namespace toit {

static const word STDIN_READ_EVENT = 1 << 0;

StdinEventSource* StdinEventSource::instance_ = null;

StdinEventSource::StdinEventSource()
    : LazyEventSource("Stdin", 1)
    , Thread("Stdin")
    , changed_(OS::allocate_condition_variable(mutex())) {
  ASSERT(instance_ == null);
  instance_ = this;
}

StdinEventSource::~StdinEventSource() {
  OS::dispose(changed_);
  instance_ = null;
}

bool StdinEventSource::start() {
  stopping_ = false;
  size_ = -1;
  error_ = 0;
  return spawn();
}

void StdinEventSource::stop() {
  {
    Locker locker(mutex());
    stopping_ = true;
    OS::signal_all(changed_);
  }
  cancel();
  join();
}

void StdinEventSource::on_register_resource(Locker& locker, Resource* resource) {
  if (size_ >= 0 || error_ != 0) {
    dispatch(locker, resource, STDIN_READ_EVENT);
  } else {
    OS::signal(changed_);
  }
}

void StdinEventSource::on_unregister_resource(Locker& locker, Resource* resource) {
  OS::signal(changed_);
}

int StdinEventSource::data_size(int* error) {
  Locker locker(mutex());
  *error = error_;
  return size_;
}

int StdinEventSource::read(uint8* destination, int size, int* error) {
  Locker locker(mutex());
  *error = error_;
  if (error_ != 0 || size_ < 0) return -1;
  if (size_ == 0) return 0;

  int result = Utils::min(size, size_);
  memcpy(destination, buffer_, result);
  if (result < size_) {
    memmove(buffer_, buffer_ + result, size_ - result);
    size_ -= result;
  } else {
    size_ = -1;
    OS::signal(changed_);
  }
  return result;
}

void StdinEventSource::entry() {
  Locker locker(mutex());
  while (!stopping_) {
    while (!stopping_ && (resources().is_empty() || size_ >= 0 || error_ != 0)) {
      OS::wait(changed_);
    }
    if (stopping_) return;

    int read_count;
    int error = 0;
    {
      Unlocker unlock(locker);
#ifdef TOIT_WINDOWS
      DWORD count = 0;
      HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
      BOOL success = input != INVALID_HANDLE_VALUE &&
          ReadFile(input, buffer_, BUFFER_SIZE, &count, NULL);
      if (!success) error = GetLastError();
      read_count = success ? static_cast<int>(count) : -1;
#else
      while (true) {
        do {
          read_count = ::read(STDIN_FILENO, buffer_, BUFFER_SIZE);
        } while (read_count < 0 && errno == EINTR);
        if (read_count >= 0) break;
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
          error = errno;
          break;
        }

        // The host package marks stdin non-blocking when it opens its own
        // standard stream. Wait here so both APIs can coexist; whichever one
        // completes a read first consumes the data.
        pollfd descriptor = { STDIN_FILENO, POLLIN, 0 };
        int poll_result;
        do {
          poll_result = poll(&descriptor, 1, -1);
        } while (poll_result < 0 && errno == EINTR);
        if (poll_result < 0) {
          error = errno;
          read_count = -1;
          break;
        }
      }
#endif
    }

    if (stopping_) return;
    if (read_count < 0) {
      error_ = error;
    } else {
      size_ = read_count;
    }
    for (auto resource : resources()) {
      dispatch(locker, resource, STDIN_READ_EVENT);
    }
  }
}

}  // namespace toit

#endif  // !defined(TOIT_FREERTOS)
