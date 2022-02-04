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

#ifdef TOIT_FREERTOS
#include <esp_wifi.h>
#endif

#if defined(TOIT_FREERTOS) || defined(TOIT_USE_LWIP)
#include <lwip/ip_addr.h>

#include "../resource.h"
#include "../objects_inline.h"
#include "../process.h"
#include "../process_group.h"
#include "../vm.h"

#include "../event_sources/lwip_esp32.h"

#include "tcp.h"
#include "tcp_esp32.h"

namespace toit {

// It has to be possible to call this twice because it is called from the
// process shutdown, but also from the finalizer if the GC spots it.
void LwIPSocket::tear_down() {
  if (_tpcb != null) {
    if (_kind == LwIPSocket::kConnection) {
      tcp_recv(_tpcb, null);
      tcp_sent(_tpcb, null);
    } else {
      tcp_accept(_tpcb, null);
    }
    tcp_arg(_tpcb, null);

    err_t err = tcp_close(_tpcb);
    if (err != ERR_OK) {
      FATAL("tcp_close failed with error %d\n", err);
    }

    _tpcb = null;
  }

  if (_read_buffer != null) {
    pbuf_free(_read_buffer);
    _read_buffer = null;
  }

  while (LwIPSocket* unaccepted_socket = _backlog.remove_first()) {
    unaccepted_socket->tear_down();
    delete unaccepted_socket;
  }
}

class SocketResourceGroup : public ResourceGroup {
 public:
  TAG(SocketResourceGroup);
  SocketResourceGroup(Process* process, LwIPEventSource* event_source)
      : ResourceGroup(process, event_source)
      , _event_source(event_source) {}

  LwIPEventSource* event_source() { return _event_source; }

 protected:
  virtual void on_unregister_resource(Resource* r) {
    // Tear down sockets on the lwip-thread.
    event_source()->call_on_thread([&]() -> Object* {
      r->as<LwIPSocket*>()->tear_down();
      return Smi::from(0);
    });
  }

 private:
  LwIPEventSource* _event_source;
};

void LwIPSocket::on_accept(tcp_pcb* tpcb, err_t err) {
  Locker locker(LwIPEventSource::instance()->mutex());

  if (err != ERR_OK) {
    socket_error(err);
    return;
  }

  new_backlog_socket(tpcb);
  send_state();
}

void LwIPSocket::on_connected(err_t err) {
  Locker locker(LwIPEventSource::instance()->mutex());

  if (err == ERR_OK) {
    tcp_recv(_tpcb, on_read);
    send_state();
  } else {
    socket_error(err);
  }
}

void LwIPSocket::on_read(pbuf* p, err_t err) {
  Locker locker(LwIPEventSource::instance()->mutex());

  if (err != ERR_OK) {
    socket_error(err);
    return;
  }

  if (p == null) {
    _read_closed = true;
  } else {
    pbuf* e = _read_buffer;
    if (e != null) {
      pbuf_cat(e, p);
    } else {
      _read_buffer = p;
    }
  }

  send_state();
}

void LwIPSocket::on_wrote(int length) {
  Locker locker(LwIPEventSource::instance()->mutex());

  _send_pending -= length;

  if (_send_closed && _send_pending == 0) {
    err_t err = tcp_shutdown(_tpcb, 0, 1);
    if (err != ERR_OK) socket_error(err);
    return;
  }

  // All done, send event.
  send_state();
}

void LwIPSocket::on_error(err_t err) {
  _tpcb = null;
  if (err == ERR_CLSD) {
    _read_closed = true;
  } else {
    socket_error(err);
  }
}


void LwIPSocket::send_state() {
  uint32_t state = 0;

  if (_read_buffer != null) state |= TCP_READ;
  if (!_backlog.is_empty()) state |= TCP_READ;
  if (!_send_closed && tpcb() != null && tcp_sndbuf(tpcb()) > 0) state |= TCP_WRITE;
  if (_read_closed) state |= TCP_READ;
  if (_error != ERR_OK) state |= TCP_ERROR;

  // TODO: Avoid instance usage.
  LwIPEventSource::instance()->set_state(this, state);
}

void LwIPSocket::socket_error(err_t err) {
  set_tpcb(null);
  _error = err;
  send_state();
}

void LwIPSocket::new_backlog_socket(tcp_pcb* tpcb) {
  LwIPSocket* socket = _new LwIPSocket(resource_group(), kConnection);
  socket->set_tpcb(tpcb);

  tcp_arg(tpcb, socket);
  tcp_err(tpcb, on_error);
  tcp_recv(tpcb, on_read);

  _backlog.append(socket);
}

// May return null if there is nothing in the backlog.
LwIPSocket* LwIPSocket::accept() {
  return _backlog.remove_first();
}

MODULE_IMPLEMENTATION(tcp, MODULE_TCP)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  SocketResourceGroup* resource_group = _new SocketResourceGroup(process, LwIPEventSource::instance());
  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(listen) {
  ARGS(SocketResourceGroup, resource_group, String, address, int, port, int, backlog);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  LwIPSocket* socket = _new LwIPSocket(resource_group, LwIPSocket::kListening);

  ip_addr_t bind_address;
  if (address->is_empty() || address->slow_equals("0.0.0.0")) {
    bind_address = *IP_ADDR_ANY;
  } else if (address->slow_equals("localhost") || address->slow_equals("127.0.0.1")) {
    IP_ADDR4(&bind_address, 127, 0, 0, 1);
  } else {
    // We currently only implement binding to localhost or IN_ADDR_ANY.
    UNIMPLEMENTED_PRIMITIVE;
  }

  CAPTURE6(
      SocketResourceGroup*, resource_group,
      LwIPSocket*, socket,
      int, port,
      int, backlog,
      ip_addr_t&, bind_address,
      Process*, process);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    Process* process = capture.process;

    tcp_pcb* tpcb = tcp_new();
    if (tpcb == null) {
      delete capture.socket;
      return lwip_error(process, ERR_MEM);
    }

    tpcb->so_options |= SOF_REUSEADDR;

    err_t err = tcp_bind(tpcb, &capture.bind_address, capture.port);
    if (err != ERR_OK) {
      delete capture.socket;
      return lwip_error(process, err);
    }

    tpcb = tcp_listen_with_backlog(tpcb, capture.backlog);
    if (tpcb == null) {
      delete capture.socket;
      return lwip_error(process, ERR_MEM);
    }

    capture.socket->set_tpcb(tpcb);
    tcp_arg(tpcb, capture.socket);

    tcp_accept(tpcb, LwIPSocket::on_accept);

    capture.resource_group->register_resource(capture.socket);

    resource_proxy->set_external_address(capture.socket);
    return resource_proxy;
  });
}

PRIMITIVE(connect) {
  ARGS(SocketResourceGroup, resource_group, Blob, address, int, port, int, window_size);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  LwIPSocket* socket = _new LwIPSocket(resource_group, LwIPSocket::kConnection);
  if (socket == null) MALLOC_FAILED;

  ip_addr_t addr;
  if (address.length() == 4) {
    const uint8_t* a = address.address();
    IP_ADDR4(&addr, a[0], a[1], a[2], a[3]);
  } else {
    OUT_OF_BOUNDS;
  }

  CAPTURE5(
      SocketResourceGroup*, resource_group,
      int, port,
      LwIPSocket*, socket,
      ip_addr_t&, addr,
      Process*, process);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    Process* process = capture.process;

    tcp_pcb* tpcb = tcp_new();
    if (tpcb == null) {
      delete capture.socket;
      return lwip_error(process, ERR_MEM);
    }

    capture.socket->set_tpcb(tpcb);
    tcp_arg(tpcb, capture.socket);
    tcp_err(tpcb, LwIPSocket::on_error);

    err_t err = tcp_connect(tpcb, &capture.addr, capture.port, LwIPSocket::on_connected);
    if (err != ERR_OK) {
      capture.socket->tear_down();
      delete capture.socket;
      return lwip_error(process, err);
    }

    capture.resource_group->register_resource(capture.socket);

    resource_proxy->set_external_address(capture.socket);
    return resource_proxy;
  });
}

PRIMITIVE(accept) {
  ARGS(SocketResourceGroup, resource_group, LwIPSocket, listen_socket);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  CAPTURE4(
    SocketResourceGroup*, resource_group,
    LwIPSocket*, listen_socket,
    ByteArray*, resource_proxy,
    Process*, process);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    LwIPSocket* accepted = capture.listen_socket->accept();
    if (accepted == null) {
      return capture.process->program()->null_object();
    }

    capture.resource_group->register_resource(accepted);
    accepted->send_state();

    capture.resource_proxy->set_external_address(accepted);
    return capture.resource_proxy;
  });
}

static ByteArray* allocate_read_buffer(Process* process, pbuf* p, Error** error) {
  const int MAX_SIZE = 1500;

  int size = 0;
  pbuf* c = p;
  // Note that pbuf's can't be larger than MTU (<1500).
  while (size + c->len <= MAX_SIZE) {
    size += c->len;

    if (c->tot_len == c->len) break;
    c = c->next;
  }

  ByteArray* array = process->allocate_byte_array(size, error, true);
  if (array != null) return array;

  // We failed to allocate the buffer, check if we can do a smaller allocation.
  if (size == p->len) return null;

  *error = null;
  return process->allocate_byte_array(p->len, error, true);
}

PRIMITIVE(read)  {
  ARGS(SocketResourceGroup, resource_group, LwIPSocket, socket);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    if (socket->error() != ERR_OK) return lwip_error(process, socket->error());

    pbuf* p = socket->read_buffer();
    if (p == null) {
      if (socket->read_closed()) return process->program()->null_object();
      return Smi::from(-1);
    }

    Error* error = null;
    ByteArray* array = allocate_read_buffer(process, p, &error);
    if (array == null) return error;

    ByteArray::Bytes bytes(array);

    int offset = 0;
    while (offset < bytes.length()) {
      memcpy(bytes.address() + offset, p->payload, p->len);
      offset += p->len;

      pbuf* n = p->next;
      // Free the first part of the chain.
      if (n != null) pbuf_ref(n);
      pbuf_free(p);
      p = n;
    }

    socket->set_read_buffer(p);

    if (socket->tpcb() != null) tcp_recved(socket->tpcb(), offset);

    return array;
  });
}

PRIMITIVE(write) {
  ARGS(SocketResourceGroup, resource_group, LwIPSocket, socket, Blob, data, int, from, int, to);

  const uint8* content = data.address();
  if (from < 0 || from > to || to > data.length()) OUT_OF_BOUNDS;

  content += from;
  to -= from;

  if (to == 0) return Smi::from(to);

  CAPTURE4(
      LwIPSocket*, socket,
      const uint8_t*, content,
      int, to,
      Process*, process);

  Object* result = resource_group->event_source()->call_on_thread([&]() -> Object* {
    Process* process = capture.process;

    if (capture.socket->error() != ERR_OK) return lwip_error(process, capture.socket->error());

    int to = Utils::min<int>(tcp_sndbuf(capture.socket->tpcb()), capture.to);
    if (to == 0) return Smi::from(-1);

    err_t err = tcp_write(capture.socket->tpcb(), capture.content, to, TCP_WRITE_FLAG_COPY);
    if (err == ERR_OK) {
      if (tcp_nagle_disabled(capture.socket->tpcb())) {
        tcp_output(capture.socket->tpcb());
      }

      capture.socket->set_send_pending(capture.socket->send_pending() + to);
      tcp_sent(capture.socket->tpcb(), LwIPSocket::on_wrote);
    } else if (err == ERR_MEM) {
      // If send queue is empty, we know the internal allocation failed. Be sure to
      // trigger GC and retry, as there will be no tcp_sent event.
      if (tcp_sndqueuelen(capture.socket->tpcb()) == 0) MALLOC_FAILED;
      // Wait for data being processed.
      return Smi::from(-1);
    } else {
      return lwip_error(process, err);
    }

    return Smi::from(to);
  });

  return result;
}

PRIMITIVE(close_write) {
  ARGS(SocketResourceGroup, resource_group, LwIPSocket, socket);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    if (socket->error() != ERR_OK) return lwip_error(process, socket->error());
    socket->mark_send_closed();

    if (socket->send_pending() > 0) {
      // Write routine already running.
      err_t err = tcp_output(socket->tpcb());
      if (err != ERR_OK) return lwip_error(process, err);
      return process->program()->null_object();
    }

    err_t err = tcp_shutdown(socket->tpcb(), 0, 1);
    if (err != ERR_OK) return lwip_error(process, err);
    return process->program()->null_object();
  });
}

PRIMITIVE(close) {
  ARGS(SocketResourceGroup, resource_group, LwIPSocket, socket);

  resource_group->unregister_resource(socket);

  socket_proxy->clear_external_address();

  return process->program()->null_object();
}

PRIMITIVE(error) {
  ARGS(LwIPSocket, socket);
  return lwip_error(process, socket->error());
}

static Object* get_address(LwIPSocket* socket, Process* process, bool peer) {
  uint32_t address = peer ?
    ip_addr_get_ip4_u32(&socket->tpcb()->remote_ip) :
    ip_addr_get_ip4_u32(&socket->tpcb()->local_ip);
  char buffer[16];
  int length = sprintf(buffer, 
#ifdef CONFIG_IDF_TARGET_ESP32C3
 		       "%lu.%lu.%lu.%lu",
#else
		       "%d.%d.%d.%d",
#endif
                       (address >> 0) & 0xff,
                       (address >> 8) & 0xff,
                       (address >> 16) & 0xff,
                       (address >> 24) & 0xff);
  return  process->allocate_string_or_error(buffer, length);
}

PRIMITIVE(get_option) {
  ARGS(SocketResourceGroup, resource_group, LwIPSocket, socket, int, option);
  CAPTURE3(LwIPSocket*, socket, int, option, Process*, process);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    Process* process = capture.process;

    if (capture.socket->error() != ERR_OK) return lwip_error(process, capture.socket->error());

    switch (capture.option) {
      case TCP_KEEP_ALIVE:
        if (capture.socket->tpcb()->so_options & SOF_KEEPALIVE) {
          return process->program()->true_object();
        }
        return process->program()->false_object();

      case TCP_NO_DELAY:
        if (tcp_nagle_disabled(capture.socket->tpcb())) {
          return process->program()->true_object();
        }
        return process->program()->false_object();

      case TCP_WINDOW_SIZE:
        return Smi::from(TCP_SND_BUF);

      case TCP_PORT:
        return Smi::from(capture.socket->tpcb()->local_port);

      case TCP_PEER_PORT:
        return Smi::from(capture.socket->tpcb()->remote_port);

      case TCP_ADDRESS:
        return get_address(capture.socket, process, false);

      case TCP_PEER_ADDRESS:
        return get_address(capture.socket, process, true);

      default:
        return process->program()->unimplemented();
    }
  });
}

PRIMITIVE(set_option) {
  ARGS(SocketResourceGroup, resource_group, LwIPSocket, socket, int, option, Object, raw);
  CAPTURE4(LwIPSocket*, socket, Object*, raw, int, option, Process*, process);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    Process* process = capture.process;

    if (capture.socket->error() != ERR_OK) return lwip_error(process, capture.socket->error());

    switch (capture.option) {
      case TCP_KEEP_ALIVE:
        if (capture.raw == process->program()->true_object()) {
          capture.socket->tpcb()->so_options |= SOF_KEEPALIVE;
        } else if (capture.raw == process->program()->false_object()) {
          capture.socket->tpcb()->so_options &= ~SOF_KEEPALIVE;
        } else {
          return process->program()->wrong_object_type();
        }
        break;

      case TCP_NO_DELAY:
        if (capture.raw == process->program()->true_object()) {
          tcp_nagle_disable(capture.socket->tpcb());
          // Flush when disabling Nagle.
          tcp_output(capture.socket->tpcb());
        } else if (capture.raw == process->program()->false_object()) {
          tcp_nagle_enable(capture.socket->tpcb());
        } else {
          return process->program()->wrong_object_type();
        }
        break;

      case TCP_WINDOW_SIZE:
        if (!capture.raw->is_smi()) return process->program()->wrong_object_type();

      default:
        return process->program()->unimplemented();
    }

    return process->program()->null_object();
  });
}

} // namespace toit

#endif // defined(TOIT_FREERTOS) || defined(TOIT_USE_LWIP)
