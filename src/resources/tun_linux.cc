// Copyright (C) 2024 Toitware ApS.
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
#include <linux/if.h>
#include <linux/if_tun.h>
#include <netdb.h>
#include <netinet/in.h>
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

#include "socket_utils.h"
#include "tun.h"

namespace toit {


class TunResourceGroup : public ResourceGroup {
 public:
  TAG(TunResourceGroup);
  TunResourceGroup(Process* process, EventSource* event_source) : ResourceGroup(process, event_source) {}

  int create_socket() {
    int id = open("/dev/net/tun", O_RDWR);
    if (id == -1) return -1;

    if (!mark_non_blocking(id)) {
      close_keep_errno(id);
      return -1;
    }

    ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TUN | IFF_NO_PI;
    strcpy(ifr.ifr_name, "tun0");

    int err = ioctl(id, TUNSETIFF, &ifr);
    if (err < 0) {
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
    if (data & EPOLLIN) state |= TUN_READ;
    if (data & EPOLLOUT) state |= TUN_WRITE;
    if (data & EPOLLERR) state |= TUN_ERROR;
    return state;
  }
};

MODULE_IMPLEMENTATION(tun, MODULE_TUN)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  TunResourceGroup* resource_group = _new TunResourceGroup(process, EpollEventSource::instance());
  if (!resource_group) FAIL(MALLOC_FAILED);

  proxy->set_external_address(resource_group);
  return proxy;
}

static uint32 checksum_part(const uint8* data, word length, uint32 sum = 0) {
  word length_even = length - (length & 1);
  for (word i = 0; i < length_even; i += 2) {
    sum += (data[i] << 8) + data[i + 1];
  }
  if (length != length_even) {
    sum += data[length_even] << 8;
  }
  return sum;
}

static word checksum(const uint8* data, word length, uint32 sum = 0) {
  sum = checksum_part(data, length, sum);
  return ((sum & 0xFFFF) + (sum >> 16)) ^ 0xffff;
}

PRIMITIVE(receive)  {
  ARGS(ByteArray, proxy, IntResource, connection_resource);
  USE(proxy);
  int fd = connection_resource->id();

  int available = 1500;

  ByteArray* array = process->allocate_byte_array(available, /*force_external*/ true);
  if (array == null) FAIL(ALLOCATION_FAILED);

  word read = ::read(fd, ByteArray::Bytes(array).address(), available);

  if (read < 0) {
    if (errno == EWOULDBLOCK || errno == EAGAIN) return Smi::from(-1);
    return Primitive::os_error(errno, process);
  }
  if (read == 0) return process->null_object();

  // Please note that the array might change length so no ByteArray::Bytes variables can pass this point.
  array->resize_external(process, read);

  // Minimum IP header size is 20 bytes - discard.
  if (read < 20) {
    return Smi::from(-1);
  }

  ByteArray::Bytes bytes(array);

  word header_size = (bytes.address()[0] & 0x0F) << 2;
  if (header_size > read) {
    return Smi::from(-1);
  }

  if (checksum(bytes.address(), header_size) != 0) {
    // This is hit for a couple of packets, but it's not clear why.
    return Smi::from(-1);
  }

  return array;
}

PRIMITIVE(send)  {
  ARGS(ByteArray, proxy, IntResource, connection_resource, MutableBlob, data);
  USE(proxy);
  int fd = connection_resource->id();

  if (data.length() < 2) FAIL(OUT_OF_BOUNDS);
  int version = data.address()[0] >> 4;
  word header_size = (data.address()[0] & 0x0F) << 2;
  if (header_size < 20) FAIL(INVALID_ARGUMENT);
  if (header_size > data.length()) FAIL(OUT_OF_BOUNDS);

  if (version == 4) {
    // Calculate IPv4 checksum.
    data.address()[10] = 0;
    data.address()[11] = 0;
    uint16 checksum = toit::checksum(data.address(), header_size);
    data.address()[10] = checksum >> 8;
    data.address()[11] = checksum & 0xFF;
  }

  if (data.length() >= header_size + 8 && version == 4) {
    int protocol = data.address()[9];
    if (protocol == 1) {
      // Calculate ICMP checksum.
      data.address()[header_size + 2] = 0;
      data.address()[header_size + 3] = 0;
      uint16 checksum = toit::checksum(data.address() + 20, data.length() - 20);
      data.address()[header_size + 2] = checksum >> 8;
      data.address()[header_size + 3] = checksum & 0xFF;
    } else if (protocol == 17) {
      // Calculate UDP checksum.
      data.address()[header_size + 6] = 0;
      data.address()[header_size + 7] = 0;
      // Source and destination IP addresses.
      uint32 sum = toit::checksum_part(data.address() + 12, 8);
      uint8 pseudo_header[4];
      pseudo_header[0] = 0;
      pseudo_header[1] = 17;
      word length = data.length() - header_size;
      pseudo_header[2] = length >> 8;
      pseudo_header[3] = length & 0xFF;
      sum = toit::checksum_part(pseudo_header, 4, sum);
      uint16 checksum = toit::checksum(
          data.address() + header_size,
          data.length() - header_size,
          sum);
      if (checksum == 0) checksum = 0xFFFF;
      data.address()[header_size + 6] = checksum >> 8;
      data.address()[header_size + 7] = checksum & 0xFF;
    }
  }

  word sent = ::write(fd, data.address(), data.length());

  if (sent < 0) {
    if (errno == EWOULDBLOCK || errno == EAGAIN) return Smi::from(-1);
    return Primitive::os_error(errno, process);
  }

  return Primitive::integer(sent, process);
}

PRIMITIVE(close) {
  ARGS(TunResourceGroup, resource_group, IntResource, connection_resource);
  int fd = connection_resource->id();

  resource_group->close_socket(fd);

  connection_resource_proxy->clear_external_address();

  return process->null_object();
}

PRIMITIVE(open) {
  ARGS(TunResourceGroup, resource_group);
  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) FAIL(ALLOCATION_FAILED);

  int id = resource_group->create_socket();
  if (id == -1) return Primitive::os_error(errno, process);

  IntResource* resource = resource_group->register_id(id);
  ASSERT(resource);  // Malloc can't fail on Linux.

  resource_proxy->set_external_address(resource);
  return resource_proxy;
}

} // namespace toit

#endif // TOIT_LINUX && !TOIT_USE_LWIP

