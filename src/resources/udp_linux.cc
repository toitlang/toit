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

#include "udp.h"

namespace toit {

static bool mark_non_blocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags == -1) return false;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1;
}

static void close_keep_errno(int fd) {
  int err = errno;
  close(fd);
  errno = err;
}

class UdpResourceGroup : public ResourceGroup {
 public:
  TAG(UdpResourceGroup);
  UdpResourceGroup(Process* process, EventSource* event_source) : ResourceGroup(process, event_source) {}

  int create_socket() {
    // TODO: Get domain from address.
    int unix_domain = AF_INET;
    int unix_type = SOCK_DGRAM;

    int id = socket(unix_domain, unix_type, 0);
    if (id == -1) return -1;

    if (!mark_non_blocking(id)) {
      close_keep_errno(id);
      return -1;
    }

    return id;
  }

  void close_socket(int id) {
    unregister_id(id);
  }

 private:
  uint32_t on_event(Resource* resource, word data, uint32_t state) {
    return static_on_event(data, state);
  }

  static uint32_t static_on_event(word data, uint32_t state) {
    if (data & EPOLLIN) state |= UDP_READ;
    if (data & EPOLLOUT) state |= UDP_WRITE;
    if (data & EPOLLERR) state |= UDP_ERROR;
    return state;
  }
};

MODULE_IMPLEMENTATION(udp, MODULE_UDP)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  UdpResourceGroup* resource_group = _new UdpResourceGroup(process, EpollEventSource::instance());
  if (!resource_group) FAIL(MALLOC_FAILED);

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(create_socket) {
  ARGS(UdpResourceGroup, resource_group);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) FAIL(ALLOCATION_FAILED);

  int id = resource_group->create_socket();
  if (id == -1) return Primitive::os_error(errno, process);

  IntResource* resource = resource_group->register_id(id);
  if (!resource) FAIL(MALLOC_FAILED);

  resource_proxy->set_external_address(resource);
  return resource_proxy;
}

PRIMITIVE(bind_socket) {
  ARGS(ByteArray, proxy, IntResource, connection_resource, Blob, address, int, port);
  USE(proxy);
  int fd = connection_resource->id();

  struct sockaddr_in addr;
  socklen_t size = sizeof(sockaddr);
  bzero((char*)&addr, size);
  addr.sin_family = AF_INET;
  // TODO(florian): we should probably check that the size is ok.
  memcpy(&addr.sin_addr.s_addr, address.address(), address.length());
  addr.sin_port = htons(port);
  if (bind(fd, reinterpret_cast<struct sockaddr *>(&addr), size) != 0) {
    return Primitive::os_error(errno, process);
  }

  return process->null_object();
}

PRIMITIVE(bind) {
  ARGS(UdpResourceGroup, resource_group, Blob, address, int, port);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) FAIL(ALLOCATION_FAILED);

  int id = resource_group->create_socket();
  if (id == -1) return Primitive::os_error(errno, process);

  IntResource* resource = resource_group->register_id(id);
  if (!resource) FAIL(MALLOC_FAILED);
  AutoUnregisteringResource<IntResource> resource_manager(resource_group, resource);

  struct sockaddr_in addr;
  socklen_t size = sizeof(sockaddr);
  bzero((char*)&addr, size);
  addr.sin_family = AF_INET;
  // TODO(florian): we should probably check that the size is ok.
  memcpy(&addr.sin_addr.s_addr, address.address(), address.length());
  addr.sin_port = htons(port);
  if (bind(id, reinterpret_cast<struct sockaddr*>(&addr), size) != 0) {
    close_keep_errno(id);
    return Primitive::os_error(errno, process);
  }

  resource_manager.set_external_address(resource_proxy);
  return resource_proxy;
}

PRIMITIVE(connect) {
  ARGS(ByteArray, proxy, IntResource, connection, Blob, address, int, port);
  USE(proxy);
  int fd = connection->id();

  struct sockaddr_in addr;
  socklen_t size = sizeof(sockaddr);
  bzero((char*)&addr, size);
  addr.sin_family = AF_INET;
  // TODO(florian): we should probably check that the size is ok.
  memcpy(&addr.sin_addr.s_addr, address.address(), address.length());
  addr.sin_port = htons(port);
  if (connect(fd, reinterpret_cast<struct sockaddr*>(&addr), size) != 0) {
    return Primitive::os_error(errno, process);
  }

  return connection_proxy;
}

PRIMITIVE(receive) {
  ARGS(ByteArray, proxy, IntResource, connection_resource, Object, output);
  USE(proxy);
  int fd = connection_resource->id();

  // TODO: Support IPv6.
  ByteArray* address = null;
  if (is_array(output)) {
    address = process->allocate_byte_array(4);
    if (address == null) FAIL(ALLOCATION_FAILED);
  }

  int available = 0;
  if (ioctl(fd, FIONREAD, &available) == -1) {
    return Primitive::os_error(errno, process);
  }

  ByteArray* array = process->allocate_byte_array(available, /*force_external*/ true);
  if (array == null) FAIL(ALLOCATION_FAILED);

  struct sockaddr_in addr;
  bzero(&addr, sizeof(addr));
  socklen_t addr_len = sizeof(addr);
  int read = recvfrom(fd, ByteArray::Bytes(array).address(), available, 0, reinterpret_cast<sockaddr*>(&addr), &addr_len);
  if (read == -1) {
    if (errno == EWOULDBLOCK || errno == EAGAIN) {
      return Smi::from(-1);
    }
    return Primitive::os_error(errno, process);
  }
  if (read == 0) return process->null_object();

  // Please note that the array might change length so no ByteArray::Bytes variables can pass this point.
  array->resize_external(process, read);

  if (is_array(output)) {
    Array* out = Array::cast(output);
    if (out->length() < 3) FAIL(INVALID_ARGUMENT);
    out->at_put(0, array);
    memcpy(ByteArray::Bytes(address).address(), &addr.sin_addr.s_addr, 4);
    out->at_put(1, address);
    out->at_put(2, Smi::from(ntohs(addr.sin_port)));
    return out;
  }

  return array;
}

PRIMITIVE(send) {
  ARGS(ByteArray, proxy, IntResource, connection_resource, Blob, data, int, from, int, to, Object, address, int, port);
  USE(proxy);
  int fd = connection_resource->id();

  if (from < 0 || from > to || to > data.length()) FAIL(OUT_OF_BOUNDS);

  struct sockaddr_in addr_in;
  struct sockaddr* addr = null;
  size_t size = 0;
  if (address != process->null_object()) {
    bzero((char*)&addr_in, sizeof(addr_in));
    addr_in.sin_family = AF_INET;
    Blob address_bytes;
    if (!address->byte_content(process->program(), &address_bytes, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_OBJECT_TYPE);
    // TODO(florian): we are not checking that the address fits into the `s_addr`.
    memcpy(&addr_in.sin_addr.s_addr, address_bytes.address(), address_bytes.length());
    addr_in.sin_port = htons(port);
    addr = reinterpret_cast<struct sockaddr*>(&addr_in);
    size = sizeof(addr_in);
  }

  int wrote = sendto(fd, data.address() + from, to - from, 0, addr, size);
  if (wrote == -1) {
    if (errno == EWOULDBLOCK || errno == EAGAIN) return Smi::from(0);
    return Primitive::os_error(errno, process);
  }

  return Smi::from(wrote);
}

static Object* get_address_or_error(int id, Process* process, bool peer) {
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

static Object* get_port_or_error(int id, Process* process, bool peer) {
  struct sockaddr_in sin;
  socklen_t len = sizeof(sin);
  int result = peer ?
      getpeername(id, (struct sockaddr *)&sin, &len) :
      getsockname(id, (struct sockaddr *)&sin, &len);
  if (result != 0) return Primitive::os_error(errno, process);
  return Smi::from(ntohs(sin.sin_port));
}

static Object* get_bool_option(int fd, int level, int optname, Process* process) {
  int value = 0;
  socklen_t size = sizeof(value);
  if (getsockopt(fd, level, optname, &value, &size) == -1) {
    return Primitive::os_error(errno, process);
  }
  return BOOL(value != 0);
}

static Object* get_int_option(int fd, int level, int optname, Process* process) {
  int value = 0;
  socklen_t size = sizeof(value);
  if (getsockopt(fd, level, optname, &value, &size) == -1) {
    return Primitive::os_error(errno, process);
  }
  return Smi::from(value);
}

PRIMITIVE(get_option) {
  ARGS(ByteArray, proxy, IntResource, connection_resource, int, option);
  USE(proxy);
  int fd = connection_resource->id();

  switch (option) {
    case UDP_ADDRESS:
      return get_address_or_error(fd, process, false);

    case UDP_PORT:
      return get_port_or_error(fd, process, false);

    case UDP_BROADCAST:
      return get_bool_option(fd, SOL_SOCKET, SO_BROADCAST, process);

    case UDP_MULTICAST_LOOPBACK:
      return get_bool_option(fd, IPPROTO_IP, IP_MULTICAST_LOOP, process);

    case UDP_MULTICAST_TTL:
      return get_int_option(fd, IPPROTO_IP, IP_MULTICAST_TTL, process);

    case UDP_REUSE_ADDRESS:
      return get_bool_option(fd, SOL_SOCKET, SO_REUSEADDR, process);

    case UDP_REUSE_PORT:
      return get_bool_option(fd, SOL_SOCKET, SO_REUSEPORT, process);

    default:
      FAIL(UNIMPLEMENTED);
  }
}

static Object* set_bool_option(int fd, int level, int optname, Object* raw, Process* process) {
  int value = 0;
  if (raw == process->true_object()) {
    value = 1;
  } else if (raw != process->false_object()) {
    FAIL(WRONG_OBJECT_TYPE);
  }
  if (setsockopt(fd, level, optname, &value, sizeof(value)) == -1) {
    return Primitive::os_error(errno, process);
  }
  return null;
}

static Object* set_int_option(int fd, int level, int optname, Object* raw, Process* process) {
  if (!is_smi(raw)) FAIL(WRONG_OBJECT_TYPE);
  int value = Smi::value(Smi::cast(raw));
  if (setsockopt(fd, level, optname, &value, sizeof(value)) == -1) {
    return Primitive::os_error(errno, process);
  }
  return null;
}

PRIMITIVE(set_option) {
  ARGS(ByteArray, proxy, IntResource, connection_resource, int, option, Object, raw);
  USE(proxy);
  int fd = connection_resource->id();
  Object* result = null;

  switch (option) {
    case UDP_BROADCAST:
      result = set_bool_option(fd, SOL_SOCKET, SO_BROADCAST, raw, process);
      break;

    case UDP_MULTICAST_MEMBERSHIP: {
      Blob bytes;
      if (!raw->byte_content(process->program(), &bytes, STRINGS_OR_BYTE_ARRAYS)) {
        FAIL(WRONG_OBJECT_TYPE);
      }
      if (bytes.length() != 4) {
        FAIL(OUT_OF_BOUNDS);
      }
      struct ip_mreq mreq;
      memcpy(&mreq.imr_multiaddr.s_addr, bytes.address(), 4);
      mreq.imr_interface.s_addr = htonl(INADDR_ANY);
      if (setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) == -1) {
        return Primitive::os_error(errno, process);
      }
      break;
    }

    case UDP_MULTICAST_LOOPBACK:
      result = set_bool_option(fd, IPPROTO_IP, IP_MULTICAST_LOOP, raw, process);
      break;

    case UDP_MULTICAST_TTL:
      result = set_int_option(fd, IPPROTO_IP, IP_MULTICAST_TTL, raw, process);
      break;

    case UDP_REUSE_ADDRESS:
      result = set_bool_option(fd, SOL_SOCKET, SO_REUSEADDR, raw, process);
      break;

    case UDP_REUSE_PORT:
      result = set_bool_option(fd, SOL_SOCKET, SO_REUSEPORT, raw, process);
      break;

    default:
      FAIL(UNIMPLEMENTED);
  }

  if (result != null) return result;

  return process->null_object();
}

PRIMITIVE(error_number) {
  ARGS(IntResource, connection_resource);
  int fd = connection_resource->id();

  int error = 0;
  socklen_t errlen = sizeof(error);
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &errlen) != 0) {
    error = errno;
  }

  return Smi::from(error);
}

PRIMITIVE(close) {
  ARGS(UdpResourceGroup, resource_group, IntResource, connection_resource);
  int fd = connection_resource->id();

  resource_group->close_socket(fd);

  connection_resource_proxy->clear_external_address();

  return process->null_object();
}

PRIMITIVE(gc) {
  // Malloc never fails on Linux so we should never try to trigger a GC.
  UNREACHABLE();
}

} // namespace toit

#endif // TOIT_LINUX && !TOIT_USE_LWIP
