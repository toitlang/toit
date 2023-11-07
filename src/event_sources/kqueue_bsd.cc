// Copyright (C) 2018 Toitware ApS.
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

#include "../top.h"

#ifdef TOIT_BSD

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#include "../objects_inline.h"

#include "kqueue_bsd.h"

namespace toit {

enum {
  kAdd,
  kRemove,
};

bool write_full(int fd, uint8_t* data, int length) {
  int offset = 0;
  while (offset < length) {
    int wrote = write(fd, data + offset, length - offset);
    if (wrote < 0 && errno != EINTR) {
      return false;
    }
    offset += wrote;
  }
  return true;
}

bool read_full(int fd, uint8_t* data, int length) {
  int offset = 0;
  while (offset < length) {
    int wrote = read(fd, data + offset, length - offset);
    if (wrote < 0 && errno != EINTR) {
      return false;
    }
    offset += wrote;
  }
  return true;
}

KQueueEventSource* KQueueEventSource::instance_ = null;

KQueueEventSource::KQueueEventSource()
    : EventSource("KQueue")
    , Thread("KQueue") {
  ASSERT(instance_ == null);
  instance_ = this;

  kqueue_fd_ = kqueue();
  if (kqueue_fd_ < 0) {
    FATAL("failed allocating kqueue file descriptor: %d", errno)
  }

  int fds[2];
  if (pipe(fds) != 0) {
    FATAL("failed allocating pipe file descriptors: %d", errno)
  }

  control_read_ = fds[0];
  control_write_ = fds[1];

  struct kevent event;
  EV_SET(&event, control_read_, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, null);
  int ret = kevent(kqueue_fd_, &event, 1, null, 0, null);
  if (ret != 0) FATAL("failed adding close fd: %d", ret);

  spawn();
}

KQueueEventSource::~KQueueEventSource() {
  close(control_write_);
  join();
  close(kqueue_fd_);

  instance_ = null;
}

void KQueueEventSource::on_register_resource(Locker& locker, Resource* r) {
  auto resource = static_cast<IntResource*>(r);
  uint64_t cmd = resource->id();
  cmd <<= 32;
  cmd |= kAdd;
  if (!write_full(control_write_, reinterpret_cast<uint8_t*>(&cmd), sizeof(cmd))) {
    FATAL("failed to send 0x%llx to kqueue: %d", cmd, errno);
  }
}

void KQueueEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  auto resource = static_cast<IntResource*>(r);
  uint64_t cmd = resource->id();
  cmd <<= 32;
  cmd |= kRemove;
  if (!write_full(control_write_, reinterpret_cast<uint8_t*>(&cmd), sizeof(cmd))) {
    FATAL("failed to send 0x%llx to kqueue: %d", cmd, errno);
  }
}

void KQueueEventSource::entry() {
  while (true) {
    struct kevent event;
    int ready = kevent(kqueue_fd_, null, 0, &event, 1, null);
    switch (ready) {
      case 1: {
        if (int(event.ident) == control_read_) {
          if (event.flags & EV_EOF) {
            close(control_read_);
            return;
          }

          uint64_t cmd = 0;
          if (!read_full(control_read_, reinterpret_cast<uint8_t*>(&cmd), sizeof(cmd))) {
            FATAL("failed to receive 0x%llx in epoll: %d", cmd, errno);
          }

          int id = cmd >> 32;
          switch (cmd & ((1LL << 32) - 1)) {
            case kAdd: {
              struct kevent event;
              EV_SET(&event, id, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, null);
              int ret = kevent(kqueue_fd_, &event, 1, null, 0, null);
              if (ret != 0) FATAL("failed adding event/read: %d for id %d", ret, id);

              if (id > 0) {
                EV_SET(&event, id, EVFILT_WRITE, EV_ADD | EV_CLEAR, 0, 0, null);
                ret = kevent(kqueue_fd_, &event, 1, null, 0, null);
                if (ret != 0) FATAL("failed adding event/write: %d for id %d", ret, id);
              }
            }
            break;

            case kRemove: {
              struct kevent event;
              EV_SET(&event, id, EVFILT_READ, EV_DELETE, 0, 0, null);
              int ret = kevent(kqueue_fd_, &event, 1, null, 0, null);
              if (ret != 0) FATAL("failed removing event/read: %d for id %d", ret, id);

              if (id > 0) {
                EV_SET(&event, id, EVFILT_WRITE, EV_DELETE, 0, 0, null);
                ret = kevent(kqueue_fd_, &event, 1, null, 0, null);
                if (ret != 0) FATAL("failed removing event/write: %d for id %d", ret, id);
              }
              close(id);
            }
            break;
          }

          continue;
        }

        Locker locker(mutex());
        Resource* r = find_resource_by_id(locker, event.ident);
        if (r != null) dispatch(locker, r, reinterpret_cast<word>(&event));
        break;
      }

      case 0:
        // No events (timeout), loop.
        break;

      case  -1: {
        if (errno == EINTR) {
          // No events (timeout), loop.
          break;
        }
        // FALL THROUGH.
      }

      default:
        FATAL("error waiting for kqueue events");
        break;
    }
  }
}

} // namespace toit

#endif // TOIT_BSD
