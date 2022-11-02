// Copyright (C) 2022 Toitware ApS.
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

#if defined(TOIT_WINDOWS)
#include "posix_socket_address.h"
#include "error_win.h"

#include <windows.h>

#include <sys/types.h>

#include "../objects_inline.h"
#include "../process_group.h"
#include "../vm.h"

#include "../event_sources/event_win.h"

#include "udp.h"

namespace toit {

class UDPResourceGroup : public ResourceGroup {
 public:
  TAG(UDPResourceGroup);
  UDPResourceGroup(Process* process, EventSource* event_source) : ResourceGroup(process, event_source) {}

 private:
  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    return reinterpret_cast<WindowsResource*>(resource)->on_event(
        reinterpret_cast<HANDLE>(data),
        state);
  }
};

const int READ_BUFFER_SIZE = 1 << 16;

class UDPSocketResource : public WindowsResource {
 public:
  TAG(UDPSocketResource);
  UDPSocketResource(UDPResourceGroup* resource_group, SOCKET socket, HANDLE read_event, HANDLE write_event)
    : WindowsResource(resource_group)
    , _socket(socket) {
    _read_buffer.buf = _read_data;
    _read_buffer.len = READ_BUFFER_SIZE;
    _read_overlapped.hEvent = read_event;
    _write_overlapped.hEvent = write_event;
    set_state(UDP_WRITE);
    if (!issue_read_request()) {
      set_state(UDP_WRITE | UDP_ERROR);
      _error_code = GetLastError();
    };
  }

  ~UDPSocketResource() override {
    if (_write_buffer.buf) free(_write_buffer.buf);
  }

  SOCKET socket() const { return _socket; }
  DWORD read_count() const { return _read_count; }
  char* read_buffer() const { return _read_buffer.buf; }
  ToitSocketAddress& read_peer_address() { return _read_peer_address; }
  DWORD error_code() const { return _error_code; }
  bool ready_for_read() const { return _read_ready; }
  bool ready_for_write() const { return _write_ready; }

  std::vector<HANDLE> events() override {
    return std::vector<HANDLE>({ _read_overlapped.hEvent, _write_overlapped.hEvent });
  }

  uint32_t on_event(HANDLE event, uint32_t state) override {
    if (event == _read_overlapped.hEvent) {
      _read_ready = true;
      state |= UDP_READ;
    } else if (event == _write_overlapped.hEvent) {
      _write_ready = true;
      state |= UDP_WRITE;
    }

    return state;
  }

  void do_close() override {
    closesocket(_socket);
    CloseHandle(_read_overlapped.hEvent);
    CloseHandle(_write_overlapped.hEvent);
  }

  bool issue_read_request() {
    _read_ready = false;
    _read_count = 0;
    DWORD flags = 0;
    int receive_result = WSARecvFrom(_socket, &_read_buffer, 1, NULL, &flags,
                                     _read_peer_address.as_socket_address(),
                                     _read_peer_address.size_pointer(),
                                     &_read_overlapped, NULL);
    if (receive_result == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING) {
      return false;
    }
    return true;
  }

  bool receive_read_response() {
    DWORD flags;
    bool overlapped_result = WSAGetOverlappedResult(_socket, &_read_overlapped, &_read_count, false, &flags);
    return overlapped_result;
  }

  bool send(const uint8* buffer, int length, ToitSocketAddress* socket_address) {
    // We need to copy the buffer out to a long-lived heap object
    if (_write_buffer.buf != null) {
      free(_write_buffer.buf);
      _write_buffer.buf = null;
    }

    _write_ready = false;

    _write_buffer.buf = static_cast<char*>(malloc(length));
    memcpy(_write_buffer.buf, buffer, length);
    _write_buffer.len = length;

    int send_result;
    DWORD tmp;
    if (socket_address) {
      send_result = WSASendTo(_socket, &_write_buffer, 1, &tmp, 0,
                              socket_address->as_socket_address(),
                              socket_address->size(),
                              &_write_overlapped, NULL);
    } else {
      send_result = WSASend(_socket, &_write_buffer, 1, &tmp, 0, &_write_overlapped, NULL);
    }

    if (send_result == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING) {
      return false;
    }

    return true;
  }

 private:
  SOCKET _socket;

  WSABUF _read_buffer{};
  char _read_data[READ_BUFFER_SIZE]{};
  OVERLAPPED _read_overlapped{};
  DWORD _read_count = 0;
  ToitSocketAddress _read_peer_address;
  bool _read_ready = false;

  WSABUF _write_buffer{};
  OVERLAPPED _write_overlapped{};
  bool _write_ready = true;

  DWORD _error_code = ERROR_SUCCESS;
};

MODULE_IMPLEMENTATION(udp, MODULE_UDP)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  auto resource_group = _new UDPResourceGroup(process, WindowsEventSource::instance());
  if (!resource_group) MALLOC_FAILED;

  if (!WindowsEventSource::instance()->use()) {
    resource_group->tear_down();
    WINDOWS_ERROR;
  }

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(bind) {
  ARGS(UDPResourceGroup, resource_group, Blob, address, int, port);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  SOCKET socket = WSASocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP, NULL, 0, WSA_FLAG_OVERLAPPED);
  if (socket == INVALID_SOCKET) WINDOWS_ERROR;

  int yes = 1;
  if (setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&yes), sizeof(yes)) == SOCKET_ERROR) {
    close_keep_errno(socket);
    WINDOWS_ERROR;
  }

  ToitSocketAddress socket_address(address.address(), address.length(), port);
  if (bind(socket, socket_address.as_socket_address(), socket_address.size()) != 0) {
    close_keep_errno(socket);
    WINDOWS_ERROR;
  }

  WSAEVENT read_event = WSACreateEvent();
  if (read_event == WSA_INVALID_EVENT) {
    close_keep_errno(socket);
    WINDOWS_ERROR;
  }

  WSAEVENT write_event = WSACreateEvent();
  if (write_event == WSA_INVALID_EVENT) {
    close_keep_errno(socket);
    close_handle_keep_errno(read_event);
    WINDOWS_ERROR;
  }

  auto resource = _new UDPSocketResource(resource_group, socket, read_event, write_event);
  if (!resource) {
    close_keep_errno(socket);
    close_handle_keep_errno(read_event);
    close_handle_keep_errno(write_event);
    MALLOC_FAILED;
  }

  resource_group->register_resource(resource);

  AutoUnregisteringResource<UDPSocketResource> resource_manager(resource_group, resource);

  resource_manager.set_external_address(resource_proxy);
  return resource_proxy;
}

PRIMITIVE(connect) {
  ARGS(ByteArray, proxy, UDPSocketResource, udp_resource, Blob, address, int, port);
  USE(proxy);
  
  ToitSocketAddress socket_address(address.address(), address.length(), port);

  if (connect(udp_resource->socket(), socket_address.as_socket_address(), socket_address.size()) != 0) {
    WINDOWS_ERROR;
  }

  return udp_resource_proxy;
}

PRIMITIVE(send) {
  ARGS(ByteArray, proxy, UDPSocketResource, udp_resource, Blob, data, int, from, int, to, Object, address, int, port);
  USE(proxy);

  if (from < 0 || from > to || to > data.length()) OUT_OF_BOUNDS;

  if (!udp_resource->ready_for_write()) return Smi::from(-1);

  bool send_result;
  const uint8* send_buffer = data.address() + from;
  int send_size = to - from;

  if (address != process->program()->null_object()) {
    Blob address_bytes;
    if (!address->byte_content(process->program(), &address_bytes, STRINGS_OR_BYTE_ARRAYS)) WRONG_TYPE;

    ToitSocketAddress socket_address(address_bytes.address(), address_bytes.length(), port);
    send_result = udp_resource->send(send_buffer, send_size, &socket_address);
  } else {
    send_result = udp_resource->send(send_buffer, send_size, null);
  }
  if (!send_result) WINDOWS_ERROR;

  return Smi::from(to-from);
}

PRIMITIVE(receive) {
  ARGS(ByteArray, proxy, UDPSocketResource, udp_resource, Object, output);
  USE(proxy);

  if (!udp_resource->ready_for_read()) return Smi::from(-1);

  // TODO: Support IPv6.
  ByteArray* address = null;
  if (is_array(output)) {
    address = process->allocate_byte_array(4);
    if (address == null) ALLOCATION_FAILED;
  }

  if (!udp_resource->receive_read_response()) WINDOWS_ERROR;

  ByteArray* array = process->allocate_byte_array(static_cast<int>(udp_resource->read_count()));
  if (array == null) ALLOCATION_FAILED;

  memcpy(ByteArray::Bytes(array).address(), udp_resource->read_buffer(), udp_resource->read_count());

  if (!udp_resource->issue_read_request()) WINDOWS_ERROR;

  if (is_array(output)) {
    Array* out = Array::cast(output);
    if (out->length() != 3) INVALID_ARGUMENT;
    out->at_put(0, array);
    ToitSocketAddress& read_peer_address = udp_resource->read_peer_address();
    memcpy(ByteArray::Bytes(address).address(), read_peer_address.address(), read_peer_address.address_length());
    out->at_put(1, address);
    out->at_put(2, Smi::from(read_peer_address.port()));
    return out;
  }

  return array;
}

static Object* get_address_or_error(SOCKET socket, Process* process) {
  ToitSocketAddress socket_address;

  int result = socket_address.retrieve_address(socket, false);
  if (result == SOCKET_ERROR) WINDOWS_ERROR;

  return socket_address.as_toit_string(process);
}

static Object* get_port_or_error(SOCKET socket, Process* process) {
  ToitSocketAddress socket_address;

  int result = socket_address.retrieve_address(socket, false);
  if (result == SOCKET_ERROR) WINDOWS_ERROR;

  return Smi::from(socket_address.port());
}

PRIMITIVE(get_option) {
  ARGS(ByteArray, proxy, UDPSocketResource, udp_resource, int, option);
  USE(proxy);
  SOCKET socket = udp_resource->socket();

  switch (option) {
    case UDP_ADDRESS:
      return get_address_or_error(socket, process);

    case UDP_PORT:
      return get_port_or_error(socket, process);

    case UDP_BROADCAST: {
      int value = 0;
      int size = sizeof(value);
      if (getsockopt(socket, SOL_SOCKET, SO_BROADCAST, reinterpret_cast<char*>(&value), &size) == -1) {
        WINDOWS_ERROR;
      }

      return BOOL(value != 0);
    }

    default:
      return process->program()->unimplemented();
  }
}

PRIMITIVE(set_option) {
  ARGS(ByteArray, proxy, UDPSocketResource, udp_resource, int, option, Object, raw);
  USE(proxy);

  switch (option) {
    case UDP_BROADCAST: {
      int value = 0;
      if (raw == process->program()->true_object()) {
        value = 1;
      } else if (raw != process->program()->false_object()) {
        WRONG_TYPE;
      }
      if (setsockopt(udp_resource->socket(), SOL_SOCKET, SO_BROADCAST,
                     reinterpret_cast<char*>(&value), sizeof(value)) == SOCKET_ERROR) {
        WINDOWS_ERROR;
      }
      break;
    }

    default:
      return process->program()->unimplemented();
  }

  return process->program()->null_object();
}

PRIMITIVE(close) {
  ARGS(UDPResourceGroup, resource_group, UDPSocketResource, udp_resource);

  // The event source will call do_close on the resource when it is safe to close the socket
  resource_group->unregister_resource(udp_resource);

  udp_resource_proxy->clear_external_address();

  return process->program()->null_object();
}

PRIMITIVE(error) {
  ARGS(UDPSocketResource, udp_resource);
  return Primitive::unmark_from_error(windows_error(process, udp_resource->error_code()));
}

PRIMITIVE(gc) {
  // This implementation never sets the NEED_GC state
  UNREACHABLE();
}

} // namespace toit

#endif // TOIT_WINDOWS
