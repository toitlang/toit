// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "../top.h"

#ifdef TOIT_LINUX

#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/epoll.h>

#include "ble_hci_packet_linux.h"
#include "../primitive.h"
#include "../objects_inline.h"
#include "../process.h"
#include "../resource.h"
#include "../event_sources/epoll_linux.h"

namespace toit {

// Linux's sockaddr_hci UAPI and protocol/channel identifiers. Keep this small
// transport independent of BlueZ development headers and libraries.
struct HciSocketAddress {
  sa_family_t family;
  uint16 device;
  uint16 channel;
};
static const int kHciProtocol = 1;     // BTPROTO_HCI.
static const int kHciUserChannel = 1;  // HCI_CHANNEL_USER.

class BleHciResourceGroup : public ResourceGroup {
 public:
  TAG(BleHciResourceGroup);
  explicit BleHciResourceGroup(Process* process)
      : ResourceGroup(process, EpollEventSource::instance()) {}

 private:
  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    if (data & EPOLLIN) state |= 1;
    if (data & EPOLLOUT) state |= 2;
    if (data & (EPOLLERR | EPOLLHUP)) state |= 4;
    return state;
  }
};

MODULE_IMPLEMENTATION(ble_hci, MODULE_BLE_HCI)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  auto group = _new BleHciResourceGroup(process);
  if (group == null) FAIL(MALLOC_FAILED);
  proxy->set_external_address(group);
  return proxy;
}

static Object* open_channel(Process* process, BleHciResourceGroup* group, int adapter, int channel) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  int fd = socket(AF_BLUETOOTH, SOCK_RAW | SOCK_NONBLOCK | SOCK_CLOEXEC, kHciProtocol);
  if (fd == -1) return Primitive::os_error(errno, process);
  HciSocketAddress address = {};
  address.family = AF_BLUETOOTH;
  address.device = adapter;
  address.channel = channel;
  if (bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
    int error = errno;
    ::close(fd);
    return Primitive::os_error(error, process);
  }
  IntResource* resource = group->register_id(fd);
  if (resource == null) {
    ::close(fd);
    FAIL(MALLOC_FAILED);
  }
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(open) {
  ARGS(BleHciResourceGroup, group, int, adapter);
  if (adapter < 0 || adapter >= 0xffff) FAIL(OUT_OF_RANGE);
  return open_channel(process, group, adapter, kHciUserChannel);
}

PRIMITIVE(open_management) {
  ARGS(BleHciResourceGroup, group);
  // HCI_DEV_NONE and HCI_CHANNEL_CONTROL. Commands carry their adapter index.
  return open_channel(process, group, 0xffff, 3);
}

PRIMITIVE(receive) {
  ARGS(IntResource, resource, int, limit);
  if (limit < 1 || limit > ByteArray::max_internal_size_in_process()) FAIL(OUT_OF_RANGE);
  int fd = resource->id();
  ByteArray* packet = null;
  auto result = ble_hci::receive_packet(fd, limit, [&](ssize_t length) -> uint8* {
    packet = process->allocate_byte_array(length);
    if (packet == null) return nullptr;
    return ByteArray::Bytes(packet).address();
  });
  switch (result.status) {
    case ble_hci::ReceiveStatus::empty: return process->null_object();
    case ble_hci::ReceiveStatus::too_large: FAIL(OUT_OF_RANGE);
    case ble_hci::ReceiveStatus::allocation_failed: FAIL(ALLOCATION_FAILED);
    case ble_hci::ReceiveStatus::os_error: return Primitive::os_error(result.error, process);
    case ble_hci::ReceiveStatus::invalid: FAIL(ERROR);
    case ble_hci::ReceiveStatus::ready: break;
  }
  return packet;
}

PRIMITIVE(send) {
  ARGS(IntResource, resource, Blob, packet);
  if (packet.length() == 0) FAIL(INVALID_ARGUMENT);
  // The syscall copies synchronously; no managed pointer survives this call.
  ssize_t sent;
  do {
    sent = send(resource->id(), packet.address(), packet.length(), MSG_DONTWAIT | MSG_NOSIGNAL);
  } while (sent < 0 && errno == EINTR);
  if (sent < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return BOOL(false);
    return Primitive::os_error(errno, process);
  }
  if (sent != packet.length()) FAIL(ERROR);
  return BOOL(true);
}

PRIMITIVE(close) {
  ARGS(BleHciResourceGroup, group, IntResource, resource);
  if (resource->resource_group() != group) FAIL(INVALID_ARGUMENT);
  group->unregister_id(resource->id());
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(diagnostics) {
  ARGS(IntResource, resource);
  // Linux owns the packet queue; these VHCI counters are unavailable here.
  return process->null_object();
}

PRIMITIVE(tx_power) {
  // Linux exposes no standard transmit power control for LE controllers.
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(test) {
#ifdef TOIT_BLE_HCI_TESTING
  ARGS(BleHciResourceGroup, group, int, action, Blob, packet);
  if (packet.length() != 0) FAIL(INVALID_ARGUMENT);
  if (action != 0) FAIL(INVALID_ARGUMENT);
  // Allocate every managed object before acquiring native descriptors. A
  // primitive allocation failure can then retry without leaking a socket pair.
  Array* result = process->object_heap()->allocate_array(2, Smi::zero());
  if (result == null) FAIL(ALLOCATION_FAILED);
  ByteArray* first = process->object_heap()->allocate_proxy();
  if (first == null) FAIL(ALLOCATION_FAILED);
  ByteArray* second = process->object_heap()->allocate_proxy();
  if (second == null) FAIL(ALLOCATION_FAILED);
  int fds[2];
  if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, 0, fds) != 0) {
    return Primitive::os_error(errno, process);
  }
  // Keep backpressure deterministic without filling the machine's socket budget.
  int send_buffer = 4096;
  for (int fd : fds) {
    if (setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send_buffer, sizeof(send_buffer)) != 0) {
      int error = errno;
      ::close(fds[0]);
      ::close(fds[1]);
      return Primitive::os_error(error, process);
    }
  }
  IntResource* first_resource = group->register_id(fds[0]);
  if (first_resource == null) {
    ::close(fds[0]);
    ::close(fds[1]);
    FAIL(MALLOC_FAILED);
  }
  IntResource* second_resource = group->register_id(fds[1]);
  if (second_resource == null) {
    group->unregister_id(fds[0]);
    ::close(fds[1]);
    FAIL(MALLOC_FAILED);
  }
  first->set_external_address(first_resource);
  second->set_external_address(second_resource);
  result->at_put(0, first);
  result->at_put(1, second);
  return result;
#else
  FAIL(UNIMPLEMENTED);
#endif
}

} // namespace toit

#endif // TOIT_LINUX
