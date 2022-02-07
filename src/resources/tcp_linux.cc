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

#if defined(TOIT_LINUX) && !defined(TOIT_USE_LWIP)

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/epoll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include "../objects.h"
#include "../objects_inline.h"
#include "../os.h"
#include "../primitive.h"
#include "../process_group.h"
#include "../process.h"
#include "../resource.h"
#include "../vm.h"

#include "../event_sources/epoll_linux.h"

#include "tcp.h"

namespace toit {

bool mark_non_blocking(int fd) {
   int flags = fcntl(fd, F_GETFL, 0);
   if (flags == -1) return false;
   return fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1;
}

void close_keep_errno(int fd) {
  int err = errno;
  close(fd);
  errno = err;
}

class SocketResourceGroup : public ResourceGroup {
 public:
  TAG(SocketResourceGroup);
  SocketResourceGroup(Process* process, EventSource* event_source) : ResourceGroup(process, event_source) {}

  int create_socket() {
    // TODO: Get domain from address.
    int unix_domain = AF_INET;
    int unix_type = SOCK_STREAM;

    int id = socket(unix_domain, unix_type, 0);
    if (id == -1) return -1;

    if (!mark_non_blocking(id)) {
      close_keep_errno(id);
      return -1;
    }

    int yes = 1;
    if (setsockopt(id, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes)) == -1) {
      close_keep_errno(id);
      return -1;
    }

    return id;
  }

  int accept(int id) {
    socklen_t size;
    int fd = ::accept(id, null, &size);
    return fd;
  }

  void close_socket(int id) {
    unregister_id(id);
  }

 private:
  uint32_t on_event(Resource* resource, word data, uint32_t state) {
    return static_on_event(data, state);
  }

  static uint32_t static_on_event(word data, uint32_t state) {
    if (data & EPOLLIN) state |= TCP_READ;
    if (data & EPOLLOUT) state |= TCP_WRITE;
    if (data & EPOLLHUP) state |= TCP_CLOSE;
    if (data & EPOLLERR) state |= TCP_ERROR;
    return state;
  }
};

int bind_socket(int fd, const char* address, int port) {
  socklen_t size = sizeof(sockaddr);
  struct sockaddr_in addr;
  bzero((char*)&addr, size);
  addr.sin_family = AF_INET;
  if (strlen(address) == 0) {
    addr.sin_addr.s_addr = INADDR_ANY;
  } else {
    struct hostent* server = gethostbyname(address);
    bcopy((char*)server->h_addr, (char*)&addr.sin_addr.s_addr, server->h_length);
  }
  addr.sin_port = htons(port);
  return bind(fd, reinterpret_cast<struct sockaddr*>(&addr), size);
}

MODULE_IMPLEMENTATION(tcp, MODULE_TCP)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  SocketResourceGroup* resource_group = _new SocketResourceGroup(process, EpollEventSource::instance());
  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(SocketResourceGroup, resource_group, IntResource, fd_resource);
  int fd = fd_resource->id();

  resource_group->close_socket(fd);

  fd_resource_proxy->clear_external_address();

  return process->program()->null_object();
}

PRIMITIVE(close_write) {
  ARGS(ByteArray, proxy, IntResource, fd_resource);
  USE(proxy);
  int fd = fd_resource->id();

  int result = shutdown(fd, SHUT_WR);
  if (result != 0) return Primitive::os_error(errno, process);

  return process->program()->null_object();
}

PRIMITIVE(connect) {
  ARGS(SocketResourceGroup, resource_group, Blob, address, int, port, int, window_size);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  int id = resource_group->create_socket();
  if (id == -1) return Primitive::os_error(errno, process);

  if (window_size != 0 && setsockopt(id, SOL_SOCKET, SO_RCVBUF, &window_size, sizeof(window_size)) == -1) {
    close(id);
    return Primitive::os_error(errno, process);
  }

  struct sockaddr_in addr;
  socklen_t size = sizeof(sockaddr);
  bzero((char*)&addr, size);
  addr.sin_family = AF_INET;
  // TODO(florian): we aren't checking that the byte-array isn't too big for the
  // s_addr.
  memcpy(&addr.sin_addr.s_addr, address.address(), address.length());
  addr.sin_port = htons(port);
  int result = connect(id, reinterpret_cast<struct sockaddr*>(&addr), size);
  if (result != 0 && errno != EINPROGRESS) {
    close(id);
    ASSERT(errno > 0);
    return Primitive::os_error(errno, process);
  }

  IntResource* resource = resource_group->register_id(id);
  if (!resource) {
    close(id);
    MALLOC_FAILED;
  }

  resource_proxy->set_external_address(resource);
  return resource_proxy;
}

PRIMITIVE(accept) {
  ARGS(SocketResourceGroup, resource_group, IntResource, listen_fd_resource);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  int listen_fd = listen_fd_resource->id();

  int fd = resource_group->accept(listen_fd);
  if (fd == -1) {
    if (errno == EWOULDBLOCK) {
      return process->program()->null_object();
    }
    return Primitive::os_error(errno, process);
  }

  IntResource* resource = resource_group->register_id(fd);
  if (!resource) {
    close(fd);
    MALLOC_FAILED;
  }
  AutoUnregisteringResource<IntResource> resource_manager(resource_group, resource);

  if (!mark_non_blocking(fd)) {
    close_keep_errno(fd);
    return Primitive::os_error(errno, process);
  }

  resource_manager.set_external_address(resource_proxy);
  return resource_proxy;
}

PRIMITIVE(listen) {
  ARGS(SocketResourceGroup, resource_group, cstring, hostname, int, port, int, backlog);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  int id = resource_group->create_socket();
  if (id == -1) return Primitive::os_error(errno, process);

  int result = bind_socket(id, hostname, port);
  if (result != 0) {
    close(id);
    if (result == -1) return Primitive::os_error(errno, process);
    WRONG_TYPE;
  }

  if (listen(id, backlog) == -1) {
    close(id);
    return Primitive::os_error(errno, process);
  }

  IntResource* resource = resource_group->register_id(id);
  if (!resource) {
    close(id);
    MALLOC_FAILED;
  }

  resource_proxy->set_external_address(resource);
  return resource_proxy;
}

PRIMITIVE(write) {
  ARGS(ByteArray, proxy, IntResource, fd_resource, Blob, data, int, from, int, to);
  USE(proxy);
  int fd = fd_resource->id();

  if (from < 0 || from > to || to > data.length()) OUT_OF_BOUNDS;

  int wrote = send(fd, data.address() + from, to - from, MSG_NOSIGNAL);
  if (wrote == -1) {
    if (errno == EWOULDBLOCK) return Smi::from(-1);
    return Primitive::os_error(errno, process);
  }

  return Smi::from(wrote);
}

PRIMITIVE(read)  {
  ARGS(ByteArray, proxy, IntResource, fd_resource);
  USE(proxy);
  int fd = fd_resource->id();

  int available = 0;
  if (ioctl(fd, FIONREAD, &available) == -1) {
    return Primitive::os_error(errno, process);
  }

  available = Utils::max(available, ByteArray::MIN_IO_BUFFER_SIZE);
  available = Utils::min(available, ByteArray::PREFERRED_IO_BUFFER_SIZE);

  Error* error = null;
  ByteArray* array = process->allocate_byte_array(available, &error, /*force_external = */ true);
  if (array == null) return error;

  int read = recv(fd, ByteArray::Bytes(array).address(), available, 0);
  if (read == -1) {
    if (errno == EWOULDBLOCK) return Smi::from(-1);
    return Primitive::os_error(errno, process);
  }
  if (read == 0) return process->program()->null_object();

  array->resize_external(read);

  return array;
}

PRIMITIVE(error) {
  ARGS(IntResource, fd_resource);
  int fd = fd_resource->id();

  int error = 0;
  socklen_t errlen = sizeof(error);
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &errlen) != 0) {
    error = errno;
  }
  return process->allocate_string_or_error(strerror(error));
}

static Object* get_address(int id, Process* process, bool peer) {
  struct sockaddr_in sin;
  socklen_t len = sizeof(sin);
  int result = peer ?
      getpeername(id, (struct sockaddr *)&sin, &len) :
      getsockname(id, (struct sockaddr *)&sin, &len);

  if (result != 0) return Primitive::os_error(errno, process);
  char buffer[16];
  uint32_t addr_word = ntohl(sin.sin_addr.s_addr);
  sprintf(buffer, "%d.%d.%d.%d",
      (addr_word >> 24) & 0xff,
      (addr_word >> 16) & 0xff,
      (addr_word >> 8) & 0xff,
      (addr_word >> 0) & 0xff);
  return process->allocate_string_or_error(buffer);
}

static Object* get_port(int id, Process* process, bool peer) {
  struct sockaddr_in sin;
  socklen_t len = sizeof(sin);
  int result = peer ?
      getpeername(id, (struct sockaddr *)&sin, &len) :
      getsockname(id, (struct sockaddr *)&sin, &len);
  if (result != 0) return Primitive::os_error(errno, process);
  return Smi::from(ntohs(sin.sin_port));
}

PRIMITIVE(get_option) {
  ARGS(ByteArray, proxy, IntResource, resource, int, option);
  USE(proxy);
  int fd = resource->id();

  switch (option) {
    case TCP_ADDRESS:
      return get_address(fd, process, false);

    case TCP_PEER_ADDRESS:
      return get_address(fd, process, true);

    case TCP_PORT:
      return get_port(fd, process, false);

    case TCP_PEER_PORT:
      return get_port(fd, process, true);

    case TCP_KEEP_ALIVE: {
      int value = 0;
      socklen_t size = sizeof(value);
      if (getsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &value, &size) == -1) {
        return Primitive::os_error(errno, process);
      }

      return BOOL(value != 0);
    }

    case TCP_NO_DELAY: {
      int value = 0;
      socklen_t size = sizeof(value);
      if (getsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &value, &size) == -1) {
        return Primitive::os_error(errno, process);
      }

      return BOOL(value != 0);
    }

    case TCP_WINDOW_SIZE: {
      int value = 0;
      socklen_t size = sizeof(value);
      if (getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &value, &size) == -1) {
        return Primitive::os_error(errno, process);
      }

      // From http://man7.org/linux/man-pages/man7/socket.7.html
      //   "The kernel doubles this value (to allow space for bookkeeping
      //    overhead) when it is set using setsockopt(2), and this doubled
      //    value is returned by getsockopt(2)."
      return Smi::from(value / 2);
    }

    default:
      return process->program()->unimplemented();
  }
}

PRIMITIVE(set_option) {
  ARGS(ByteArray, proxy, IntResource, fd_resource, int, option, Object, raw);
  USE(proxy);
  int fd = fd_resource->id();

  switch (option) {
    case TCP_KEEP_ALIVE: {
      int value = 0;
      if (raw == process->program()->true_object()) {
        value = 1;
      } else if (raw != process->program()->false_object()) {
        WRONG_TYPE;
      }
      if (setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &value, sizeof(value)) == -1) {
        return Primitive::os_error(errno, process);
      }
      break;
    }

    case TCP_NO_DELAY: {
      int value = 0;
      if (raw == process->program()->true_object()) {
        value = 1;
      } else if (raw != process->program()->false_object()) {
        WRONG_TYPE;
      }
      if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &value, sizeof(value)) == -1) {
        return Primitive::os_error(errno, process);
      }
      break;
    }

    default:
      return process->program()->unimplemented();
  }

  return process->program()->null_object();
}

} // namespace toit

#endif // TOIT_LINUX && !TOIT_USE_LWIP
