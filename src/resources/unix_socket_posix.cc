// Copyright (C) 2026 Toit contributors.
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

#if defined(TOIT_LINUX) || defined(TOIT_BSD)

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#ifdef TOIT_LINUX
#include <sys/epoll.h>
#else
#include <sys/event.h>
#endif

#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../event_sources/epoll_linux.h"
#include "../event_sources/kqueue_bsd.h"
#include "unix_socket.h"

namespace toit {

class UnixSocketResourceGroup : public ResourceGroup {
 public:
  TAG(UnixSocketResourceGroup);
  UnixSocketResourceGroup(Process* process, EventSource* source) : ResourceGroup(process, source) {}

 private:
  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
#ifdef TOIT_LINUX
    if (data & EPOLLIN) state |= UNIX_SOCKET_READ;
    if (data & EPOLLOUT) state |= UNIX_SOCKET_WRITE;
    if (data & EPOLLHUP) state |= UNIX_SOCKET_CLOSE;
    if (data & EPOLLERR) state |= UNIX_SOCKET_ERROR;
#else
    struct kevent* event = reinterpret_cast<struct kevent*>(data);
    if (event->filter == EVFILT_READ) {
      state |= UNIX_SOCKET_READ;
      // A read EOF is a half-close; writes may still succeed.
    }
    if (event->filter == EVFILT_WRITE) state |= UNIX_SOCKET_WRITE;
    if ((event->flags & EV_EOF) && event->fflags != 0) state |= UNIX_SOCKET_ERROR;
#endif
    return state;
  }
};

// Owns a descriptor until it has been handed to the event source.
class UnixSocketFd {
 public:
  explicit UnixSocketFd(int fd) : fd_(fd) {}
  ~UnixSocketFd() {
    if (fd_ >= 0) {
      int saved_errno = errno;
      ::close(fd_);
      errno = saved_errno;
    }
  }
  void release() { fd_ = -1; }
 private:
  int fd_;
};

static bool configure_socket(int fd) {
#ifdef TOIT_BSD
  int flags = fcntl(fd, F_GETFL);
  if (flags == -1 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1) return false;
  flags = fcntl(fd, F_GETFD);
  if (flags == -1 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == -1) return false;
  int yes = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) == -1) return false;
#endif
  return true;
}

static int create_socket() {
#ifdef TOIT_LINUX
  return socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
#else
  return socket(AF_UNIX, SOCK_STREAM, 0);
#endif
}

static bool make_address(const Blob& path, sockaddr_un* address, socklen_t* length) {
  // Only filesystem paths are supported. Check bytes, not Unicode characters.
  if (path.length() == 0 || path.length() >= static_cast<word>(sizeof(address->sun_path)) ||
      memchr(path.address(), 0, path.length()) != null) return false;
  memset(address, 0, sizeof(*address));
  address->sun_family = AF_UNIX;
  memcpy(address->sun_path, path.address(), path.length());
  *length = offsetof(sockaddr_un, sun_path) + path.length() + 1;
#ifdef TOIT_BSD
  address->sun_len = *length;
#endif
  return true;
}

MODULE_IMPLEMENTATION(unix_socket, MODULE_UNIX_SOCKET)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
#ifdef TOIT_LINUX
  EventSource* source = EpollEventSource::instance();
#else
  EventSource* source = KQueueEventSource::instance();
#endif
  UnixSocketResourceGroup* group = _new UnixSocketResourceGroup(process, source);
  if (group == null) FAIL(MALLOC_FAILED);
  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(connect) {
  ARGS(UnixSocketResourceGroup, group, Blob, path);
  sockaddr_un address;
  socklen_t length;
  if (!make_address(path, &address, &length)) FAIL(INVALID_ARGUMENT);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  int fd = create_socket();
  if (fd == -1) return Primitive::os_error(errno, process);
  UnixSocketFd owner(fd);
  if (!configure_socket(fd)) return Primitive::os_error(errno, process);
  int result = ::connect(fd, reinterpret_cast<sockaddr*>(&address), length);
  // EAGAIN on Linux means the listener's queue is full, not a pending
  // connection. Surface the error and let the caller retry with a new socket.
  // EINTR likewise leaves connection state uncertain; close rather than retry.
  if (result == -1 && errno != EINPROGRESS) return Primitive::os_error(errno, process);
  IntResource* resource = group->register_id(fd);
  if (resource == null) FAIL(MALLOC_FAILED);
  owner.release();
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(listen) {
  ARGS(UnixSocketResourceGroup, group, Blob, path, int, backlog);
  sockaddr_un address;
  socklen_t length;
  if (!make_address(path, &address, &length) || backlog < 0) FAIL(INVALID_ARGUMENT);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  int fd = create_socket();
  if (fd == -1) return Primitive::os_error(errno, process);
  UnixSocketFd owner(fd);
  if (!configure_socket(fd)) return Primitive::os_error(errno, process);
  // Allocate before binding, but register only after listen: an unconnected
  // descriptor can generate a spurious hangup notification.
  IntResource* resource = _new IntResource(group, fd);
  if (resource == null) FAIL(MALLOC_FAILED);
  if (::bind(fd, reinterpret_cast<sockaddr*>(&address), length) == -1 || ::listen(fd, backlog) == -1) {
    int error = errno;
    delete resource;
    return Primitive::os_error(error, process);
  }
  group->register_resource(resource);
  owner.release();
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(accept) {
  ARGS(UnixSocketResourceGroup, group, IntResource, listener);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  int fd;
  do {
#ifdef TOIT_LINUX
    fd = accept4(listener->id(), null, null, SOCK_NONBLOCK | SOCK_CLOEXEC);
#else
    fd = ::accept(listener->id(), null, null);
#endif
  } while (fd == -1 && errno == EINTR);
  if (fd == -1) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return process->null_object();
    return Primitive::os_error(errno, process);
  }
  UnixSocketFd owner(fd);
  if (!configure_socket(fd)) return Primitive::os_error(errno, process);
  IntResource* resource = group->register_id(fd);
  if (resource == null) FAIL(MALLOC_FAILED);
  owner.release();
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(read) {
  ARGS(UnixSocketResourceGroup, group, IntResource, resource);
  USE(group);
  ByteArray* array = process->allocate_byte_array(ByteArray::PREFERRED_IO_BUFFER_SIZE, true);
  if (array == null) FAIL(ALLOCATION_FAILED);
  ssize_t count;
  do {
    count = recv(resource->id(), ByteArray::Bytes(array).address(), ByteArray::PREFERRED_IO_BUFFER_SIZE, 0);
  } while (count == -1 && errno == EINTR);
  if (count == -1) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return Smi::from(-1);
    return Primitive::os_error(errno, process);
  }
  if (count == 0) return process->null_object();
  array->resize_external(process, count);
  return array;
}

PRIMITIVE(write) {
  ARGS(UnixSocketResourceGroup, group, IntResource, resource, Blob, data, int, from, int, to);
  USE(group);
  if (from < 0 || from > to || to > data.length()) FAIL(OUT_OF_BOUNDS);
  int flags = 0;
#ifdef TOIT_LINUX
  flags = MSG_NOSIGNAL;
#endif
  ssize_t count;
  do {
    count = send(resource->id(), data.address() + from, to - from, flags);
  } while (count == -1 && errno == EINTR);
  if (count == -1) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return Smi::from(-1);
    return Primitive::os_error(errno, process);
  }
  return Smi::from(count);
}

PRIMITIVE(close_write) {
  ARGS(UnixSocketResourceGroup, group, IntResource, resource);
  USE(group);
  int result;
  do {
    result = shutdown(resource->id(), SHUT_WR);
  } while (result == -1 && errno == EINTR);
  if (result == -1) return Primitive::os_error(errno, process);
  return process->null_object();
}

PRIMITIVE(close) {
  ARGS(UnixSocketResourceGroup, group, IntResource, resource);
  group->unregister_id(resource->id());
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(error_number) {
  ARGS(IntResource, resource);
  int error = 0;
  socklen_t length = sizeof(error);
  if (getsockopt(resource->id(), SOL_SOCKET, SO_ERROR, &error, &length) == -1) error = errno;
  return Smi::from(error);
}

PRIMITIVE(error) {
  ARGS(int, error);
  return process->allocate_string_or_error(strerror(error));
}

PRIMITIVE(path) {
  ARGS(IntResource, resource, bool, peer);
  sockaddr_un address;
  memset(&address, 0, sizeof(address));
  socklen_t length = sizeof(address);
  int result = peer
      ? getpeername(resource->id(), reinterpret_cast<sockaddr*>(&address), &length)
      : getsockname(resource->id(), reinterpret_cast<sockaddr*>(&address), &length);
  if (result == -1) return Primitive::os_error(errno, process);
  if (length <= offsetof(sockaddr_un, sun_path) || address.sun_path[0] == 0) {
    // Unnamed (or a peer in the unsupported Linux abstract namespace).
    return process->null_object();
  }
  size_t size = Utils::min(static_cast<size_t>(length - offsetof(sockaddr_un, sun_path)),
                         sizeof(address.sun_path));
  return process->allocate_string_or_error(address.sun_path, strnlen(address.sun_path, size));
}

}  // namespace toit

#endif  // TOIT_LINUX || TOIT_BSD
