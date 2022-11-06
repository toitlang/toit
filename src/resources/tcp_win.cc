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

#ifdef TOIT_WINDOWS

#include <winsock2.h>
#include <windows.h>

#include "posix_socket_address.h"

#include <sys/time.h>

#include "../objects_inline.h"
#include "../process_group.h"

#include "../event_sources/event_win.h"

#include "tcp.h"
#include "error_win.h"

namespace toit {

class TCPResourceGroup : public ResourceGroup {
 public:
  TAG(TCPResourceGroup);
  TCPResourceGroup(Process* process, EventSource* event_source) : ResourceGroup(process, event_source) {}

  static SOCKET create_socket() {
    SOCKET socket = WSASocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0, WSA_FLAG_OVERLAPPED);
    if (socket == INVALID_SOCKET) return socket;
    return socket;
  }

 private:
  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    return reinterpret_cast<WindowsResource*>(resource)->on_event(
        reinterpret_cast<HANDLE>(data),
        state);
  }
};

class SocketResource : public WindowsResource {
 public:
  SocketResource(TCPResourceGroup* resource_group, SOCKET socket)
    : WindowsResource(resource_group)
    , socket_(socket) {}
  SOCKET socket() const { return socket_; }
  void do_close() override {
    closesocket(socket_);
  }

 private:
  SOCKET socket_;
};

const int READ_BUFFER_SIZE = 1 << 16;

class TCPSocketResource : public SocketResource {
 public:
  TAG(TCPSocketResource);
  TCPSocketResource(TCPResourceGroup* resource_group, SOCKET socket,
                    HANDLE read_event, HANDLE write_event, HANDLE auxiliary_event)
      : SocketResource(resource_group, socket)
      , auxiliary_event_(auxiliary_event) {
    read_buffer_.buf = read_data_;
    read_buffer_.len = READ_BUFFER_SIZE;
    read_overlapped_.hEvent = read_event;
    write_overlapped_.hEvent = write_event;
    if (!issue_read_request()) {
      int error_code = WSAGetLastError();
      if (error_code == WSAECONNRESET) {
        set_state(TCP_CLOSE);
      } else {
        error_code_ = WSAGetLastError();
        set_state(TCP_ERROR);
      }
    } else {
      set_state(TCP_WRITE);
    }
  }

  ~TCPSocketResource() override {
    if (write_buffer_.buf != null) free(write_buffer_.buf);
  }

  DWORD read_count() const { return read_count_; }
  char* read_buffer() const { return read_buffer_.buf; }
  bool ready_for_write() const { return write_ready_; }
  bool ready_for_read() const { return read_ready_; }
  bool closed() const { return closed_; }
  int error_code() const { return error_code_; }

  std::vector<HANDLE> events() override {
    return std::vector<HANDLE>({
                                   read_overlapped_.hEvent,
                                   write_overlapped_.hEvent,
                                   auxiliary_event_
      });
  }

  uint32_t on_event(HANDLE event, uint32_t state) override {
    if (event == read_overlapped_.hEvent) {
      read_ready_ = true;
      state |= TCP_READ;
    } else if (event == write_overlapped_.hEvent) {
      write_ready_ = true;
      state |= TCP_WRITE;
    } else if (event == auxiliary_event_) {
      WSANETWORKEVENTS network_events;
      if (WSAEnumNetworkEvents(socket(), NULL, &network_events) == SOCKET_ERROR) {
        error_code_ = WSAGetLastError();
        state |= TCP_ERROR;
      };
      if (network_events.lNetworkEvents & FD_CLOSE) {
        if (network_events.iErrorCode[FD_CLOSE_BIT] == 0) {
          state |= TCP_READ;
        } else {
          error_code_ = network_events.iErrorCode[FD_CLOSE_BIT];
          closed_ = true;
          state |= TCP_CLOSE | TCP_READ;
        }
      }
    } else if (event == INVALID_HANDLE_VALUE) {
      // The event source sends INVALID_HANDLE_VALUE when the socket is closed.
      error_code_ = WSAECONNRESET;
      closed_ = true;
      state |= TCP_CLOSE | TCP_READ;
    }
    return state;
  }

  void do_close() override {
    SocketResource::do_close();
    CloseHandle(read_overlapped_.hEvent);
    CloseHandle(write_overlapped_.hEvent);
  }

  bool issue_read_request() {
    read_ready_ = false;
    read_count_ = 0;
    DWORD flags = 0;
    int receive_result = WSARecv(socket(), &read_buffer_, 1, NULL, &flags, &read_overlapped_, NULL);
    if (receive_result == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING) {
      return false;
    }
    return true;
  }

  bool receive_read_response() {
    DWORD flags;
    bool overlapped_result = WSAGetOverlappedResult(socket(), &read_overlapped_, &read_count_, false, &flags);
    if (read_count_ == 0) closed_ = true;
    return overlapped_result;
  }

  bool send(const uint8* buffer, int length) {
    if (write_buffer_.buf != null) {
      free(write_buffer_.buf);
      write_buffer_.buf = null;
    }

    write_ready_ = false;

    // We need to copy the buffer out to a long-lived heap object
    write_buffer_.buf = static_cast<char*>(malloc(length));
    if (!write_buffer_.buf) {
      WSASetLastError(ERROR_NOT_ENOUGH_MEMORY);
      return false;
    }
    memcpy(write_buffer_.buf, buffer, length);
    write_buffer_.len = length;

    int send_result = WSASend(socket(), &write_buffer_, 1, NULL, 0, &write_overlapped_, NULL);

    if (send_result == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING) {
      return false;
    }
    return true;
  }

 private:
  WSABUF read_buffer_{};
  char read_data_[READ_BUFFER_SIZE]{};
  OVERLAPPED read_overlapped_{};
  DWORD read_count_ = 0;
  bool read_ready_ = false;

  WSABUF write_buffer_{};
  OVERLAPPED write_overlapped_{};
  bool write_ready_ = true;

  HANDLE auxiliary_event_;
  bool closed_ = false;
  int error_code_ = 0;
};

class TCPServerSocketResource : public SocketResource {
 public:
  TAG(TCPServerSocketResource);
  TCPServerSocketResource(TCPResourceGroup* resource_group, SOCKET socket, HANDLE event)
    : SocketResource(resource_group, socket)
    , event_(event) {}

  std::vector<HANDLE> events() override {
    return std::vector<HANDLE>({event_ });
  }

  uint32_t on_event(HANDLE event, uint32_t state) override {
    return state | TCP_READ;
  }

  void do_close() override {
    SocketResource::do_close();
    CloseHandle(event_);
  }

 private:
  HANDLE event_;
};

MODULE_IMPLEMENTATION(tcp, MODULE_TCP)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  auto resource_group = _new TCPResourceGroup(process, WindowsEventSource::instance());
  if (!resource_group) MALLOC_FAILED;

  if (!WindowsEventSource::instance()->use()) {
    resource_group->tear_down();
    WINDOWS_ERROR;
  }

  proxy->set_external_address(resource_group);
  return proxy;
}

static HeapObject* create_events(Process* process, SOCKET socket, WSAEVENT& read_event,
                                 WSAEVENT& write_event, WSAEVENT& auxiliary_event) {
  auxiliary_event = WSACreateEvent();
  if (auxiliary_event == WSA_INVALID_EVENT) {
    WINDOWS_ERROR;
  }

  if (WSAEventSelect(socket, auxiliary_event, FD_CLOSE) == SOCKET_ERROR) {
    close_handle_keep_errno(auxiliary_event);
    WINDOWS_ERROR;
  }

  read_event = WSACreateEvent();
  if (read_event == WSA_INVALID_EVENT) {
    close_handle_keep_errno(auxiliary_event);
    WINDOWS_ERROR;
  }

  write_event = WSACreateEvent();
  if (write_event == WSA_INVALID_EVENT) {
    close_handle_keep_errno(read_event);
    close_handle_keep_errno(auxiliary_event);
    WINDOWS_ERROR;
  }

  return null;
}

PRIMITIVE(connect) {
  ARGS(TCPResourceGroup, resource_group, Blob, address, int, port, int, window_size);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  SOCKET socket = TCPResourceGroup::create_socket();
  if (socket == INVALID_SOCKET) WINDOWS_ERROR;

  if (window_size != 0 && setsockopt(socket, SOL_SOCKET, SO_RCVBUF,
                                     reinterpret_cast<char*>(&window_size), sizeof(window_size)) == -1) {
    close_keep_errno(socket);
    WINDOWS_ERROR;
  }

  ToitSocketAddress socket_address(address.address(), address.length(), port);
  int result = connect(socket, socket_address.as_socket_address(), socket_address.port());
  if (result == SOCKET_ERROR && WSAGetLastError() != WSAEINPROGRESS) {
    close_keep_errno(socket);
    WINDOWS_ERROR;
  }

  WSAEVENT read_event, write_event, auxiliary_event;
  auto error = create_events(process, socket, read_event, write_event, auxiliary_event);

  if (error) {
    close_keep_errno(socket);
    return error;
  }

  auto tcp_resource = _new TCPSocketResource(resource_group, socket, read_event, write_event, auxiliary_event);
  if (!tcp_resource) {
    close_keep_errno(socket);
    close_handle_keep_errno(read_event);
    close_handle_keep_errno(write_event);
    close_handle_keep_errno(auxiliary_event);
    MALLOC_FAILED;
  }

  resource_group->register_resource(tcp_resource);

  resource_proxy->set_external_address(tcp_resource);

  return resource_proxy;
}

PRIMITIVE(accept) {
  ARGS(TCPResourceGroup, resource_group, TCPServerSocketResource, server_socket_resource);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  SOCKET socket = accept(server_socket_resource->socket(), NULL, NULL);
  if (socket == INVALID_SOCKET) {
    if (WSAGetLastError() == WSAEWOULDBLOCK)
      return process->program()->null_object();
    WINDOWS_ERROR;
  }

  WSAEVENT read_event, write_event, auxiliary_event;
  auto error = create_events(process, socket, read_event, write_event, auxiliary_event);
  if (error) {
    close_keep_errno(socket);
    return error;
  }

  auto tcp_resource = _new TCPSocketResource(resource_group, socket, read_event, write_event, auxiliary_event);

  if (!tcp_resource) {
    close_keep_errno(socket);
    close_handle_keep_errno(read_event);
    close_handle_keep_errno(write_event);
    MALLOC_FAILED;
  }

  resource_group->register_resource(tcp_resource);

  resource_proxy->set_external_address(tcp_resource);

  return resource_proxy;
}

PRIMITIVE(listen) {
  ARGS(TCPResourceGroup, resource_group, cstring, hostname, int, port, int, backlog);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  ToitSocketAddress socket_address;
  if (!socket_address.lookup_address(hostname, port)) {
    WINDOWS_ERROR;
  };

  SOCKET socket = TCPResourceGroup::create_socket();
  if (socket == INVALID_SOCKET) WINDOWS_ERROR;
  if (bind(socket, socket_address.as_socket_address(), socket_address.size()) == SOCKET_ERROR) {
    close_keep_errno(socket);
    if (WSAGetLastError() == WSAEADDRINUSE) {
      String* error = process->allocate_string("Address already in use");
      if (error == null) ALLOCATION_FAILED;
      return Error::from(error);
    }
    WINDOWS_ERROR;
  }

  if (listen(socket, backlog) == SOCKET_ERROR) {
    close_keep_errno(socket);
    WINDOWS_ERROR;
  }

  WSAEVENT event = WSACreateEvent();
  if (event == WSA_INVALID_EVENT) {
    close_keep_errno(socket);
    WINDOWS_ERROR;
  }

  if (WSAEventSelect(socket, event, FD_ACCEPT) == SOCKET_ERROR) {
    close_keep_errno(socket);
    close_handle_keep_errno(event);
    WINDOWS_ERROR;
  }

  auto resource = _new TCPServerSocketResource(resource_group, socket, event);
  if (!resource) {
    close_keep_errno(socket);
    close_handle_keep_errno(event);
    MALLOC_FAILED;
  }

  resource_group->register_resource(resource);

  resource_proxy->set_external_address(resource);
  return resource_proxy;
}

PRIMITIVE(write) {
  ARGS(ByteArray, proxy, TCPSocketResource, tcp_resource, Blob, data, int, from, int, to);
  USE(proxy);

  if (from < 0 || from > to || to > data.length()) OUT_OF_BOUNDS;

  if (!tcp_resource->ready_for_write()) return Smi::from(-1);

  if (!tcp_resource->send(data.address() + from, to - from)) WINDOWS_ERROR;

  return Smi::from(to-from);
}

PRIMITIVE(read)  {
  ARGS(ByteArray, proxy, TCPSocketResource, tcp_resource);
  USE(proxy);

  if (tcp_resource->closed()) return process->program()->null_object();

  if (!tcp_resource->ready_for_read()) return Smi::from(-1);

  if (!tcp_resource->receive_read_response()) WINDOWS_ERROR;

  // With overlapped (async) reads a read_count of 0 indicates end of stream.
  if (tcp_resource->read_count() == 0) return process->program()->null_object();

  ByteArray* array = process->allocate_byte_array(static_cast<int>(tcp_resource->read_count()));
  if (array == null) ALLOCATION_FAILED;

  memcpy(ByteArray::Bytes(array).address(), tcp_resource->read_buffer(), tcp_resource->read_count());

  if (!tcp_resource->issue_read_request()) WINDOWS_ERROR;

  return array;
}

static Object* get_address(SOCKET socket, Process* process, bool peer) {
  ToitSocketAddress socket_address;

  int result = socket_address.retrieve_address(socket, peer);
  if (result == SOCKET_ERROR) WINDOWS_ERROR;

  return socket_address.as_toit_string(process);
}

static Object* get_port(SOCKET socket, Process* process, bool peer) {
  ToitSocketAddress socket_address;

  int result = socket_address.retrieve_address(socket, peer);
  if (result == SOCKET_ERROR) WINDOWS_ERROR;

  return Smi::from(socket_address.port());
}

PRIMITIVE(get_option) {
  ARGS(ByteArray, proxy, Resource, resource, int, option);
  USE(proxy);
  SOCKET socket = reinterpret_cast<SocketResource*>(resource)->socket();

  switch (option) {
    case TCP_ADDRESS:
      return get_address(socket, process, false);

    case TCP_PEER_ADDRESS:
      return get_address(socket, process, true);

    case TCP_PORT:
      return get_port(socket, process, false);

    case TCP_PEER_PORT:
      return get_port(socket, process, true);

    case TCP_KEEP_ALIVE: {
      int value = 0;
      int size = sizeof(value);
      if (getsockopt(socket, SOL_SOCKET, SO_KEEPALIVE, reinterpret_cast<char *>(&value), &size) == -1)
        WINDOWS_ERROR;

      return BOOL(value != 0);
    }

    case TCP_WINDOW_SIZE: {
      int value = 0;
      int size = sizeof(value);
      if (getsockopt(socket, SOL_SOCKET, SO_RCVBUF, reinterpret_cast<char *>(&value), &size) == -1)
        WINDOWS_ERROR;

      return Smi::from(value);
    }

    default:
      return process->program()->unimplemented();
  }
}

PRIMITIVE(set_option) {
  ARGS(ByteArray, proxy, TCPSocketResource, tcp_resource, int, option, Object, raw);
  USE(proxy);

  if (option == TCP_KEEP_ALIVE) {
    int value = 0;
    if (raw == process->program()->true_object()) {
      value = 1;
    } else if (raw != process->program()->false_object()) {
      WRONG_TYPE;
    }
    if (setsockopt(tcp_resource->socket(), SOL_SOCKET, SO_KEEPALIVE,
                   reinterpret_cast<char*>(&value), sizeof(value)) == SOCKET_ERROR) {
      WINDOWS_ERROR;
    }
  } else {
    return process->program()->unimplemented();
  }

  return process->program()->null_object();
}

PRIMITIVE(close_write) {
  ARGS(ByteArray, proxy, TCPSocketResource, tcp_resource);
  USE(proxy);

  int result = shutdown(tcp_resource->socket(), SD_SEND);
  if (result != 0) WINDOWS_ERROR;

  return process->program()->null_object();
}

PRIMITIVE(close) {
  ARGS(TCPResourceGroup, resource_group, Resource, resource);

  // The event source will call do_close on the resource when it is safe to close the socket
  resource_group->unregister_resource(resource);

  resource_proxy->clear_external_address();

  return process->program()->null_object();
}

PRIMITIVE(error) {
  ARGS(TCPSocketResource, tcp_resource);
  return Primitive::unmark_from_error(windows_error(process, tcp_resource->error_code()));
}

PRIMITIVE(gc) {
  // This implementation never sets the NEED_GC state
  UNREACHABLE();
}

} // namespace toit
#endif // TOIT_BSD
