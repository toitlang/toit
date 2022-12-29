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

#if defined(TOIT_FREERTOS) && defined(CONFIG_TOIT_ENABLE_IP) || defined(TOIT_USE_LWIP)
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
void LwipSocket::tear_down() {
  if (tpcb_ != null) {
    if (kind_ == LwipSocket::kConnection) {
      tcp_recv(tpcb_, null);
      tcp_sent(tpcb_, null);
    } else {
      tcp_accept(tpcb_, null);
    }
    tcp_arg(tpcb_, null);

    err_t err = tcp_close(tpcb_);
    if (err != ERR_OK) {
      FATAL("tcp_close failed with error %d\n", err);
    }

    tpcb_ = null;
  }

  if (read_buffer_ != null) {
    pbuf_free(read_buffer_);
    read_buffer_ = null;
  }

  while (LwipSocket* unaccepted_socket = backlog_.remove_first()) {
    unaccepted_socket->tear_down();
    delete unaccepted_socket;
  }
}

class SocketResourceGroup : public ResourceGroup {
 public:
  TAG(SocketResourceGroup);
  SocketResourceGroup(Process* process, LwipEventSource* event_source)
      : ResourceGroup(process, event_source)
      , event_source_(event_source) {}

  LwipEventSource* event_source() { return event_source_; }

 protected:
  virtual void on_unregister_resource(Resource* r) {
    // Tear down sockets on the lwip-thread.
    event_source()->call_on_thread([&]() -> Object* {
      r->as<LwipSocket*>()->tear_down();
      return Smi::from(0);
    });
  }

 private:
  LwipEventSource* event_source_;
};

int LwipSocket::on_accept(tcp_pcb* tpcb, err_t err) {
  if (err != ERR_OK) {
    // Currently this only happend when a SYN is received and
    // there is not enough memory.  In this case err is ERR_MEM.
    // We do this to trigger a GC.  The counterpart will retransmit the
    // SYN.
    socket_error(err);

    // This return value is actually ignored in LwIP.  The socket is
    // not dead.
    return err;
  }

  int result = new_backlog_socket(tpcb);
  if (result != ERR_OK) {
    socket_error(err);
  }
  send_state();
  return result;
}

int LwipSocket::on_connected(err_t err) {
  // According to the documentation err is currently always ERR_OK, but trying
  // to be defensive here.
  if (err == ERR_OK) {
    tcp_recv(tpcb_, on_read);
  } else {
    socket_error(err);
  }
  send_state();
  return err;
}

void LwipSocket::on_read(pbuf* p, err_t err) {
  if (err != ERR_OK) {
    socket_error(err);
    return;
  }

  if (p == null) {
    read_closed_ = true;
  } else {
    pbuf* e = read_buffer_;
    if (e != null) {
      pbuf_cat(e, p);
    } else {
      read_buffer_ = p;
    }
  }

  send_state();
}

void LwipSocket::on_wrote(int length) {
  send_pending_ -= length;

  if (send_closed_ && send_pending_ == 0) {
    err_t err = tcp_shutdown(tpcb_, 0, 1);
    if (err != ERR_OK) socket_error(err);
    return;
  }

  // All done, send event.
  send_state();
}

void LwipSocket::on_error(err_t err) {
  // The tpcb_ has already been deallocated when this is called.
  tpcb_ = null;
  if (err == ERR_CLSD) {
    read_closed_ = true;
  } else if (err == ERR_MEM) {
    // If we got an allocation error that caused the connection to close
    // then it's too late for a GC and we have to throw something that
    // actually results in an exception that is visible.  Hopefully rare.
    socket_error(ERR_MEM_NON_RECOVERABLE);
  } else {
    socket_error(err);
  }
}

void LwipSocket::send_state() {
  uint32_t state = 0;

  if (read_buffer_ != null) state |= TCP_READ;
  if (!backlog_.is_empty()) state |= TCP_READ;
  if (!send_closed_ && tpcb() != null && tcp_sndbuf(tpcb()) > 0) state |= TCP_WRITE;
  if (read_closed_) state |= TCP_READ;
  if (error_ != ERR_OK) state |= TCP_ERROR;
  if (needs_gc) state |= TCP_NEEDS_GC;

  // TODO: Avoid instance usage.
  LwipEventSource::instance()->set_state(this, state);
}

void LwipSocket::socket_error(err_t err) {
  if (err == ERR_MEM) {
    needs_gc = true;
  } else {
    set_tpcb(null);
    error_ = err;
  }
  send_state();
}

int LwipSocket::new_backlog_socket(tcp_pcb* tpcb) {
  LwipSocket* socket = _new LwipSocket(resource_group(), kConnection);
  if (socket == null) {
    // We are not in a primitive, so we can't retry the operation.
    // We return ERR_ABRT to tell LwIP that the connection is dead.
    // We also trigger a GC so at least the next one will succeed.
    needs_gc = true;
    return ERR_ABRT;
  }
  socket->set_tpcb(tpcb);

  tcp_arg(tpcb, socket);
  tcp_err(tpcb, on_error);
  tcp_recv(tpcb, on_read);

  backlog_.append(socket);
  return ERR_OK;
}

// May return null if there is nothing in the backlog.
LwipSocket* LwipSocket::accept() {
  return backlog_.remove_first();
}

MODULE_IMPLEMENTATION(tcp, MODULE_TCP)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  SocketResourceGroup* resource_group = _new SocketResourceGroup(process, LwipEventSource::instance());
  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(listen) {
  ARGS(SocketResourceGroup, resource_group, String, address, int, port, int, backlog);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  LwipSocket* socket = _new LwipSocket(resource_group, LwipSocket::kListening);
  if (socket == null) MALLOC_FAILED;

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
      LwipSocket*, socket,
      int, port,
      int, backlog,
      ip_addr_t&, bind_address,
      Process*, process);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    Process* process = capture.process;

    tcp_pcb* tpcb = tcp_new();
    if (tpcb == null) {
      delete capture.socket;
      MALLOC_FAILED;
    }

    tpcb->so_options |= SOF_REUSEADDR;

    err_t err = tcp_bind(tpcb, &capture.bind_address, capture.port);
    if (err != ERR_OK) {
      delete capture.socket;
      tcp_close(tpcb);
      return lwip_error(process, err);
    }

    // The call to tcp_listen_with_backlog frees or reallocates the tpcb we
    // pass to it, so there is no need to close that one.
    tpcb = tcp_listen_with_backlog(tpcb, capture.backlog);
    if (tpcb == null) {
      delete capture.socket;
      MALLOC_FAILED;
    }

    capture.socket->set_tpcb(tpcb);
    tcp_arg(tpcb, capture.socket);

    tcp_accept(tpcb, LwipSocket::on_accept);

    capture.resource_group->register_resource(capture.socket);

    resource_proxy->set_external_address(capture.socket);
    return resource_proxy;
  });
}

PRIMITIVE(connect) {
  ARGS(SocketResourceGroup, resource_group, Blob, address, int, port, int, window_size);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  LwipSocket* socket = _new LwipSocket(resource_group, LwipSocket::kConnection);
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
      LwipSocket*, socket,
      ip_addr_t&, addr,
      Process*, process);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    Process* process = capture.process;

    tcp_pcb* tpcb = tcp_new();
    if (tpcb == null) {
      delete capture.socket;
      MALLOC_FAILED;
    }

    capture.socket->set_tpcb(tpcb);
    tcp_arg(tpcb, capture.socket);
    tcp_err(tpcb, LwipSocket::on_error);

    err_t err = tcp_connect(tpcb, &capture.addr, capture.port, LwipSocket::on_connected);
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
  ARGS(SocketResourceGroup, resource_group, LwipSocket, listen_socket);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  CAPTURE4(
    SocketResourceGroup*, resource_group,
    LwipSocket*, listen_socket,
    ByteArray*, resource_proxy,
    Process*, process);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    LwipSocket* accepted = capture.listen_socket->accept();
    if (accepted == null) {
      return capture.process->program()->null_object();
    }

    capture.resource_group->register_resource(accepted);
    accepted->send_state();

    capture.resource_proxy->set_external_address(accepted);
    return capture.resource_proxy;
  });
}

PRIMITIVE(read)  {
  ARGS(SocketResourceGroup, resource_group, LwipSocket, socket);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    if (socket->error() != ERR_OK) return lwip_error(process, socket->error());

    int offset;
    pbuf* p = socket->get_read_buffer(&offset);

    if (p == null) {
      if (socket->read_closed()) return process->program()->null_object();
      return Smi::from(-1);
    }

    int total_available = p->tot_len - offset;
    if (total_available < 0) return Smi::from(-1);

    // Wifi MTU is 1500 bytes, subtract a 20 byte TCP header and we have 1480.
    // A size of 496 gives three nicely-packable byte arrays per 1480 MTU.
    int allocation_size = Utils::min(496, total_available);
    ByteArray* array = process->allocate_byte_array(allocation_size, false);  // On-heap byte array.
    if (array == null) ALLOCATION_FAILED;

    ByteArray::Bytes bytes(array);

    int bytes_to_ack = 0;
    int copied = 0;
    while (copied < allocation_size) {
      int to_copy = Utils::min(p->len - offset, allocation_size - copied);
      uint8* payload = unvoid_cast<uint8*>(p->payload);
      memcpy(bytes.address() + copied, payload + offset, to_copy);
      copied += to_copy;
      offset += to_copy;
      if (offset == p->len) {
        pbuf* n = p->next;
        bytes_to_ack += p->len;
        // Free the first part of the chain.  Increment the ref count of the
        // next packet in the chain first, so the whole chain doesn't get
        // freed.
        if (n != null) pbuf_ref(n);
        pbuf_free(p);
        // We don't have to check for null because tot_len won't extend past the last packet.
        p = n;
        offset = 0;
      }
    }

    socket->set_read_buffer(p, offset);

    // Notify peer that we finished processing some packets and they can send
    // more on the TCP socket.
    if (socket->tpcb() != null && bytes_to_ack != 0) {
      tcp_recved(socket->tpcb(), bytes_to_ack);
    }

    return array;
  });
}

PRIMITIVE(write) {
  ARGS(SocketResourceGroup, resource_group, LwipSocket, socket, Blob, data, int, from, int, to);

  const uint8* content = data.address();
  if (from < 0 || from > to || to > data.length()) OUT_OF_BOUNDS;

  content += from;
  to -= from;

  if (to == 0) return Smi::from(to);

  CAPTURE4(
      LwipSocket*, socket,
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
      tcp_sent(capture.socket->tpcb(), LwipSocket::on_wrote);
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
  ARGS(SocketResourceGroup, resource_group, LwipSocket, socket);

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
  ARGS(SocketResourceGroup, resource_group, LwipSocket, socket);
  resource_group->unregister_resource(socket);
  socket_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(error) {
  ARGS(LwipSocket, socket);
  return lwip_error(process, socket->error());
}

static Object* get_address(LwipSocket* socket, Process* process, bool peer) {
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
  ARGS(SocketResourceGroup, resource_group, LwipSocket, socket, int, option);
  CAPTURE3(LwipSocket*, socket, int, option, Process*, process);

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
  ARGS(SocketResourceGroup, resource_group, LwipSocket, socket, int, option, Object, raw);
  CAPTURE4(LwipSocket*, socket, Object*, raw, int, option, Process*, process);

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
        if (!is_smi(capture.raw)) return process->program()->wrong_object_type();
        return process->program()->unimplemented();

      default:
        return process->program()->unimplemented();
    }

    return process->program()->null_object();
  });
}

PRIMITIVE(gc) {
  ARGS(SocketResourceGroup, group);
  Object* do_gc = group->event_source()->call_on_thread([&]() -> Object* {
    bool result = needs_gc;
    needs_gc = false;
    return BOOL(result);
  });
  if (do_gc == process->program()->true_object()) CROSS_PROCESS_GC;
  return process->program()->null_object();
}

} // namespace toit

#endif // defined(TOIT_FREERTOS) && defined(CONFIG_TOIT_ENABLE_IP) || defined(TOIT_USE_LWIP)
