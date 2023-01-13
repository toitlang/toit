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

#include "../objects.h"
#include "../objects_inline.h"
#include "../os.h"
#include "../primitive.h"
#include "../process_group.h"
#include "../process.h"
#include "../resource.h"
#include "../vm.h"

#include "../event_sources/kqueue_bsd.h"

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

class TcpResourceGroup : public ResourceGroup {
 public:
  TAG(TcpResourceGroup);
  TcpResourceGroup(Process* process, EventSource* event_source) : ResourceGroup(process, event_source) {}

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
    struct kevent* event = reinterpret_cast<struct kevent*>(data);

    if (event->filter == EVFILT_READ) {
      state |= TCP_READ;
      if (event->flags & EV_EOF) {
        if (event->fflags != 0) {
          state |= TCP_ERROR;
          // TODO: We currently don't propagate read-closed events.
        }
      }
    }

    if (event->filter == EVFILT_WRITE) {
      state |= TCP_WRITE;
      if (event->flags & EV_EOF && event->fflags != 0) {
        state |= TCP_ERROR;
      }
    }

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

  TcpResourceGroup* resource_group = _new TcpResourceGroup(process, KQueueEventSource::instance());
  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(TcpResourceGroup, resource_group, IntResource, fd_resource);
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
  ARGS(TcpResourceGroup, resource_group, Blob, address, int, port, int, window_size);

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
  // TODO(florian): This looks like we could write out of bounds. We should
  // probably check that the address_bytes_length is the right size.
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
  ARGS(TcpResourceGroup, resource_group, IntResource, listen_fd_resource);

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
  ARGS(TcpResourceGroup, resource_group, cstring, hostname, int, port, int, backlog);

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

  int wrote = send(fd, data.address() + from, to - from, 0);
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

  ByteArray* array = process->allocate_byte_array(available, /*force_external*/ true);
  if (array == null) ALLOCATION_FAILED;

  int read = recv(fd, ByteArray::Bytes(array).address(), available, 0);
  if (read == -1) {
    if (errno == EWOULDBLOCK) return Smi::from(-1);
    return Primitive::os_error(errno, process);
  }
  if (read == 0) return process->program()->null_object();

  array->resize_external(process, read);

  return array;
}

PRIMITIVE(error_number) {
  ARGS(IntResource, fd_resource);
  int fd = fd_resource->id();

  int error = 0;
  socklen_t errlen = sizeof(error);
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &errlen) != 0) {
    error = errno;
  }
  return Smi::from(error);
}

PRIMITIVE(error) {
  ARGS(int, error);
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
  snprintf(buffer, sizeof(buffer), "%d.%d.%d.%d",
      (addr_word >> 24) & 0xff,
      (addr_word >> 16) & 0xff,
      (addr_word >> 8) & 0xff,
      (addr_word >> 0) & 0xff);
  buffer[sizeof(buffer) - 1] = '\0';
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

    case TCP_WINDOW_SIZE: {
      int value = 0;
      socklen_t size = sizeof(value);
      if (getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &value, &size) == -1) {
        return Primitive::os_error(errno, process);
      }

      return Smi::from(value);
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

    default:
      return process->program()->unimplemented();
  }

  return process->program()->null_object();
}

PRIMITIVE(gc) {
  // Malloc never fails on Mac so we should never try to trigger a GC.
  UNREACHABLE();
}

} // namespace toit

#endif // TOIT_BSD
