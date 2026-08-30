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
#include <linux/sock_diag.h>
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

static bool tcp_read_debugging_enabled() {
  static bool enabled = []() {
    char* value = OS::getenv("TOIT_DEBUG_TCP_READ");
    bool result = value != null && value[0] != '\0' && strcmp(value, "0") != 0;
    free(value);
    return result;
  }();
  return enabled;
}

static int tcp_accepted_receive_buffer_override() {
  static int receive_buffer = []() {
    char* value = OS::getenv("TOIT_TCP_ACCEPT_RCVBUF");
    int result = value == null ? 0 : atoi(value);
    free(value);
    return result > 0 ? result : 0;
  }();
  return receive_buffer;
}

static int tcp_read_chunk_size_override() {
  static int chunk_size = []() {
    char* value = OS::getenv("TOIT_TCP_READ_CHUNK_SIZE");
    int result = value == null ? 0 : atoi(value);
    free(value);
    return result > 0 ? result : 0;
  }();
  return chunk_size;
}

static void print_tcp_kernel_debug_suffix(int fd) {
  int64 socket_rmem = -1;
  int64 socket_rcvbuf = -1;
  int64 socket_forward_alloc = -1;
  int64 socket_backlog = -1;
  int64 socket_drops = -1;
  uint32_t memory[SK_MEMINFO_VARS] = {};
  socklen_t memory_size = sizeof(memory);
  if (getsockopt(fd, SOL_SOCKET, SO_MEMINFO, memory, &memory_size) == 0) {
    int entries = memory_size / sizeof(memory[0]);
    if (entries > SK_MEMINFO_RMEM_ALLOC) socket_rmem = memory[SK_MEMINFO_RMEM_ALLOC];
    if (entries > SK_MEMINFO_RCVBUF) socket_rcvbuf = memory[SK_MEMINFO_RCVBUF];
    if (entries > SK_MEMINFO_FWD_ALLOC) {
      socket_forward_alloc = static_cast<int32_t>(memory[SK_MEMINFO_FWD_ALLOC]);
    }
    if (entries > SK_MEMINFO_BACKLOG) socket_backlog = memory[SK_MEMINFO_BACKLOG];
    if (entries > SK_MEMINFO_DROPS) socket_drops = memory[SK_MEMINFO_DROPS];
  }

  int64 receive_ssthresh = -1;
  int64 receive_space = -1;
  int64 receive_rtt = -1;
  int64 total_retransmissions = -1;
  int64 receive_window_clamp = -1;
  struct tcp_info info = {};
  socklen_t info_size = sizeof(info);
  if (getsockopt(fd, IPPROTO_TCP, TCP_INFO, &info, &info_size) == 0) {
    receive_ssthresh = info.tcpi_rcv_ssthresh;
    receive_space = info.tcpi_rcv_space;
    receive_rtt = info.tcpi_rcv_rtt;
    total_retransmissions = info.tcpi_total_retrans;
  }
  int window_clamp = -1;
  socklen_t window_clamp_size = sizeof(window_clamp);
  if (getsockopt(fd, IPPROTO_TCP, TCP_WINDOW_CLAMP, &window_clamp, &window_clamp_size) == 0) {
    receive_window_clamp = window_clamp;
  }

  fprintf(stderr,
      " socket_rmem=%" PRId64 " socket_rcvbuf=%" PRId64
      " socket_forward_alloc=%" PRId64 " socket_backlog=%" PRId64
      " socket_drops=%" PRId64 " tcp_rcv_ssthresh=%" PRId64
      " tcp_rcv_space=%" PRId64 " tcp_rcv_rtt_us=%" PRId64
      " tcp_total_retrans=%" PRId64 " tcp_window_clamp=%" PRId64,
      socket_rmem,
      socket_rcvbuf,
      socket_forward_alloc,
      socket_backlog,
      socket_drops,
      receive_ssthresh,
      receive_space,
      receive_rtt,
      total_retransmissions,
      receive_window_clamp);
}

class TcpResource : public IntResource {
 public:
  TcpResource(ResourceGroup* group, word id, int process_id, bool debug_reads)
      : IntResource(group, id)
      , process_id_(process_id)
      , debug_reads_(debug_reads)
      , read_ready_time_us_(0)
      , receive_buffer_(-1) {}

  void mark_read_ready() {
    if (!debug_reads_) return;

    int64 now = OS::get_system_time();
    int64 expected = 0;
    read_ready_time_us_.compare_exchange_strong(expected, now);

    int receive_buffer = -1;
    socklen_t size = sizeof(receive_buffer);
    if (getsockopt(id(), SOL_SOCKET, SO_RCVBUF, &receive_buffer, &size) != 0) return;
    int previous = receive_buffer_.exchange(receive_buffer);
    if (previous != receive_buffer) {
      flockfile(stderr);
      fprintf(stderr,
          "TOIT_TCP_READ event=receive-buffer-change timestamp_us=%" PRId64
          " os_pid=%d process=%d fd=%" PRIdPTR " previous=%d current=%d",
          now,
          getpid(),
          process_id_,
          id(),
          previous,
          receive_buffer);
      print_tcp_kernel_debug_suffix(id());
      fputc('\n', stderr);
      fflush(stderr);
      funlockfile(stderr);
    }
  }

  int64 take_read_ready_time() {
    return debug_reads_ ? read_ready_time_us_.exchange(0) : 0;
  }

  bool debug_reads() const { return debug_reads_; }

  bool has_allocation_failure() const { return allocation_failure_time_us_ != 0; }
  int64 allocation_failure_time_us() const { return allocation_failure_time_us_; }
  int allocation_failure_gc_count() const { return allocation_failure_gc_count_; }
  int allocation_failure_full_gc_count() const { return allocation_failure_full_gc_count_; }

  void record_allocation_failure(Process* process, int64 time_us) {
    allocation_failure_time_us_ = time_us;
    allocation_failure_gc_count_ = process->gc_count(NEW_SPACE_GC);
    allocation_failure_full_gc_count_ = process->gc_count(FULL_GC);
  }

  void clear_allocation_failure() { allocation_failure_time_us_ = 0; }

 private:
  int process_id_;
  bool debug_reads_;
  std::atomic<int64> read_ready_time_us_;
  std::atomic<int> receive_buffer_;
  int64 allocation_failure_time_us_ = 0;
  int allocation_failure_gc_count_ = 0;
  int allocation_failure_full_gc_count_ = 0;
};

static int debug_socket_port(int fd, bool peer) {
  sockaddr_in address;
  socklen_t size = sizeof(address);
  int result = peer
      ? getpeername(fd, reinterpret_cast<sockaddr*>(&address), &size)
      : getsockname(fd, reinterpret_cast<sockaddr*>(&address), &size);
  return result == 0 ? ntohs(address.sin_port) : -1;
}

static int debug_socket_option(int fd, int option) {
  int value = -1;
  socklen_t size = sizeof(value);
  if (getsockopt(fd, SOL_SOCKET, option, &value, &size) != 0) return -1;
  return value;
}

static void print_tcp_read_debug(
    const char* event,
    Process* process,
    TcpResource* resource,
    word bytes_available,
    word requested_size,
    int64 event_delay_us,
    int64 retry_delay_us = 0) {
  int fd = resource->id();
  ObjectHeap* heap = process->object_heap();
  flockfile(stderr);
  fprintf(stderr,
      "TOIT_TCP_READ event=%s timestamp_us=%" PRId64
      " os_pid=%d process=%d fd=%d local_port=%d peer_port=%d"
      " fionread=%" PRIdPTR " requested=%" PRIdPTR
      " event_delay_us=%" PRId64 " retry_delay_us=%" PRId64
      " rcvbuf=%d rcvlowat=%d gc=%d full_gc=%d compacting_gc=%d"
      " heap_allocated=%" PRId64 " heap_reserved=%" PRId64
      " heap_external=%" PRIuPTR " heap_limit=%" PRIuPTR
      " max_external_allocation=%" PRIdPTR " system_refused_memory=%d",
      event,
      OS::get_system_time(),
      getpid(),
      process->id(),
      fd,
      debug_socket_port(fd, false),
      debug_socket_port(fd, true),
      bytes_available,
      requested_size,
      event_delay_us,
      retry_delay_us,
      debug_socket_option(fd, SO_RCVBUF),
      debug_socket_option(fd, SO_RCVLOWAT),
      process->gc_count(NEW_SPACE_GC),
      process->gc_count(FULL_GC),
      process->gc_count(COMPACTING_GC),
      heap->bytes_allocated(),
      heap->bytes_reserved(),
      heap->external_memory(),
      heap->limit(),
      heap->max_external_allocation(),
      process->system_refused_memory());
  print_tcp_kernel_debug_suffix(fd);
  fputc('\n', stderr);
  fflush(stderr);
  funlockfile(stderr);
}

class SocketResourceGroup : public ResourceGroup {
 public:
  TAG(SocketResourceGroup);
  SocketResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source)
      , debug_reads_(tcp_read_debugging_enabled()) {}

  TcpResource* register_socket(word id) {
    TcpResource* resource = _new TcpResource(this, id, process()->id(), debug_reads_);
    if (resource) register_resource(resource);
    return resource;
  }

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
    // The actual close syscall will take place in the event loop in
    // epoll_linux.cc.
    unregister_id(id);
  }

 private:
  uint32_t on_event(Resource* resource, word data, uint32_t state) {
    if (data & EPOLLIN) static_cast<TcpResource*>(resource)->mark_read_ready();
    return static_on_event(data, state);
  }

  static uint32_t static_on_event(word data, uint32_t state) {
    if (data & EPOLLIN) state |= TCP_READ;
    if (data & EPOLLOUT) state |= TCP_WRITE;
    if (data & EPOLLHUP) state |= TCP_CLOSE;
    if (data & EPOLLERR) state |= TCP_ERROR;
    return state;
  }

  bool debug_reads_;
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
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  SocketResourceGroup* resource_group = _new SocketResourceGroup(process, EpollEventSource::instance());
  if (!resource_group) FAIL(MALLOC_FAILED);

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(SocketResourceGroup, resource_group, IntResource, fd_resource);
  int fd = fd_resource->id();

  resource_group->close_socket(fd);

  fd_resource_proxy->clear_external_address();

  return process->null_object();
}

PRIMITIVE(close_write) {
  ARGS(ByteArray, proxy, IntResource, fd_resource);
  USE(proxy);
  int fd = fd_resource->id();

  int result = shutdown(fd, SHUT_WR);
  if (result != 0) return Primitive::os_error(errno, process);

  return process->null_object();
}

PRIMITIVE(connect) {
  ARGS(SocketResourceGroup, resource_group, Blob, address, int, port, int, window_size);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) FAIL(ALLOCATION_FAILED);

  int id = resource_group->create_socket();
  if (id == -1) return Primitive::os_error(errno, process);

  if (window_size != 0 && setsockopt(id, SOL_SOCKET, SO_RCVBUF, &window_size, sizeof(window_size)) == -1) {
    close_keep_errno(id);
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
    close_keep_errno(id);
    ASSERT(errno > 0);
    return Primitive::os_error(errno, process);
  }

  TcpResource* resource = resource_group->register_socket(id);
  if (!resource) {
    close(id);
    FAIL(MALLOC_FAILED);
  }

  resource_proxy->set_external_address(resource);
  return resource_proxy;
}

PRIMITIVE(accept) {
  ARGS(SocketResourceGroup, resource_group, IntResource, listen_fd_resource);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) FAIL(ALLOCATION_FAILED);

  int listen_fd = listen_fd_resource->id();

  int fd = resource_group->accept(listen_fd);
  if (fd == -1) {
    if (errno == EWOULDBLOCK || errno == EAGAIN) {
      return process->null_object();
    }
    return Primitive::os_error(errno, process);
  }

  int receive_buffer_override = tcp_accepted_receive_buffer_override();
  if (receive_buffer_override != 0 &&
      setsockopt(
          fd,
          SOL_SOCKET,
          SO_RCVBUF,
          &receive_buffer_override,
          sizeof(receive_buffer_override)) == -1) {
    close_keep_errno(fd);
    return Primitive::os_error(errno, process);
  }
  if (receive_buffer_override != 0 && tcp_read_debugging_enabled()) {
    int actual_receive_buffer = -1;
    socklen_t option_size = sizeof(actual_receive_buffer);
    getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &actual_receive_buffer, &option_size);
    fprintf(stderr,
        "TOIT_TCP_READ event=accepted-receive-buffer-override"
        " os_pid=%d process=%d fd=%d requested=%d actual=%d\n",
        getpid(),
        process->id(),
        fd,
        receive_buffer_override,
        actual_receive_buffer);
  }

  TcpResource* resource = resource_group->register_socket(fd);
  if (!resource) {
    close(fd);
    FAIL(MALLOC_FAILED);
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
  if (resource_proxy == null) FAIL(ALLOCATION_FAILED);

  int id = resource_group->create_socket();
  if (id == -1) return Primitive::os_error(errno, process);

  int result = bind_socket(id, hostname, port);
  if (result != 0) {
    close_keep_errno(id);
    if (result == -1) return Primitive::os_error(errno, process);
    FAIL(WRONG_OBJECT_TYPE);
  }

  if (listen(id, backlog) == -1) {
    close_keep_errno(id);
    return Primitive::os_error(errno, process);
  }

  TcpResource* resource = resource_group->register_socket(id);
  if (!resource) {
    close(id);
    FAIL(MALLOC_FAILED);
  }

  resource_proxy->set_external_address(resource);
  return resource_proxy;
}

PRIMITIVE(write) {
  ARGS(ByteArray, proxy, IntResource, fd_resource, Blob, data, int, from, int, to);
  USE(proxy);
  int fd = fd_resource->id();

  if (from < 0 || from > to || to > data.length()) FAIL(OUT_OF_BOUNDS);

  int wrote = send(fd, data.address() + from, to - from, MSG_NOSIGNAL);
  if (wrote == -1) {
    if (errno == EWOULDBLOCK || errno == EAGAIN) return Smi::from(-1);
    return Primitive::os_error(errno, process);
  }

  return Smi::from(wrote);
}

PRIMITIVE(read)  {
  ARGS(ByteArray, proxy, IntResource, fd_resource);
  USE(proxy);
  int fd = fd_resource->id();
  TcpResource* resource = static_cast<TcpResource*>(fd_resource);
  int64 now = resource->debug_reads() ? OS::get_system_time() : 0;
  int64 ready_time_us = resource->take_read_ready_time();
  int64 event_delay_us = ready_time_us == 0 ? 0 : now - ready_time_us;

  word bytes_available = 0;
  if (ioctl(fd, FIONREAD, &bytes_available) == -1) {
    return Primitive::os_error(errno, process);
  }

  bool allocation_retry = resource->has_allocation_failure();
  int64 retry_delay_us = allocation_retry ? now - resource->allocation_failure_time_us() : 0;
  int failure_gc_count = resource->allocation_failure_gc_count();
  int failure_full_gc_count = resource->allocation_failure_full_gc_count();
  resource->clear_allocation_failure();

  word available = bytes_available;
  available = Utils::max(available, ByteArray::MIN_IO_BUFFER_SIZE);
  int chunk_size_override = tcp_read_chunk_size_override();
  word maximum_read_size = chunk_size_override == 0
      ? ByteArray::PREFERRED_IO_BUFFER_SIZE
      : chunk_size_override;
  available = Utils::min(available, maximum_read_size);

  ByteArray* array = process->allocate_byte_array(available, /*force_external*/ true);
  if (array == null) {
    if (resource->debug_reads()) {
      print_tcp_read_debug(
          "allocation-failed",
          process,
          resource,
          bytes_available,
          available,
          event_delay_us,
          retry_delay_us);
      resource->record_allocation_failure(process, OS::get_system_time());
    }
    FAIL(ALLOCATION_FAILED);
  }

  if (allocation_retry && resource->debug_reads()) {
    print_tcp_read_debug(
        "allocation-retry",
        process,
        resource,
        bytes_available,
        available,
        event_delay_us,
        retry_delay_us);
    fprintf(stderr,
        "TOIT_TCP_READ event=allocation-retry-gc-delta os_pid=%d process=%d fd=%d"
        " gc=%d->%d full_gc=%d->%d\n",
        getpid(),
        process->id(),
        fd,
        failure_gc_count,
        process->gc_count(NEW_SPACE_GC),
        failure_full_gc_count,
        process->gc_count(FULL_GC));
    fflush(stderr);
  } else if (resource->debug_reads() &&
      bytes_available > 0 &&
      event_delay_us >= 5 * 1000) {
    print_tcp_read_debug(
        "read-ready-delay",
        process,
        resource,
        bytes_available,
        available,
        event_delay_us);
  }

  int read = recv(fd, ByteArray::Bytes(array).address(), available, 0);
  if (read == -1) {
    if (errno == EWOULDBLOCK || errno == EAGAIN) return Smi::from(-1);
    return Primitive::os_error(errno, process);
  }
  if (read == 0) return process->null_object();

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
      FAIL(UNIMPLEMENTED);
  }
}

PRIMITIVE(set_option) {
  ARGS(ByteArray, proxy, IntResource, fd_resource, int, option, Object, raw);
  USE(proxy);
  int fd = fd_resource->id();

  switch (option) {
    case TCP_KEEP_ALIVE: {
      int value = 0;
      if (raw == process->true_object()) {
        value = 1;
      } else if (raw != process->false_object()) {
        FAIL(WRONG_OBJECT_TYPE);
      }
      if (setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &value, sizeof(value)) == -1) {
        return Primitive::os_error(errno, process);
      }
      break;
    }

    case TCP_NO_DELAY: {
      int value = 0;
      if (raw == process->true_object()) {
        value = 1;
      } else if (raw != process->false_object()) {
        FAIL(WRONG_OBJECT_TYPE);
      }
      if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &value, sizeof(value)) == -1) {
        return Primitive::os_error(errno, process);
      }
      break;
    }

    default:
      FAIL(UNIMPLEMENTED);
  }

  return process->null_object();
}

PRIMITIVE(gc) {
  // Malloc never fails on Linux so we should never try to trigger a GC.
  UNREACHABLE();
}

} // namespace toit

#endif // TOIT_LINUX && !TOIT_USE_LWIP
