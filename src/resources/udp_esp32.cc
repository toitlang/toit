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

// Some versions of LWIP convert pointers to bools in macros, and so are not
// compatible with this warning.
#pragma GCC diagnostic ignored "-Waddress"

#include "../top.h"

#if defined(TOIT_FREERTOS) || defined(TOIT_USE_LWIP)

#include <lwip/udp.h>
#include "lwip/ip_addr.h"

#include "../linked.h"
#include "../resource.h"
#include "../objects_inline.h"
#include "../process.h"
#include "../process_group.h"
#include "../vm.h"

#include "../event_sources/lwip_esp32.h"

#include "udp.h"

namespace toit {

const int MAX_QUEUE_SIZE = 1024 * 8;

class Packet : public LinkedFIFO<Packet>::Element {
 public:
  Packet(struct pbuf* pbuf, ip_addr_t addr, u16_t port)
    : _pbuf(pbuf)
    , _addr(addr)
    , _port(port) {
  }

  ~Packet() {
    pbuf_free(_pbuf);
  }

  struct pbuf* pbuf() { return _pbuf; }
  ip_addr_t addr() { return _addr; }
  u16_t port() { return _port; }

 private:
  struct pbuf* _pbuf;
  ip_addr_t _addr;
  u16_t _port;
};

class UDPSocket : public Resource {
 public:
  TAG(UDPSocket);
  UDPSocket(ResourceGroup* group, udp_pcb* upcb)
    : Resource(group)
    , _mutex(null)
    , _upcb(upcb)
    , _buffered_bytes(0) {
  }

  ~UDPSocket() {
    while (auto packet = _packages.remove_first()) {
      delete packet;
    }
  }

  void tear_down() {
    if (_upcb) {
      udp_recv(_upcb, null, null);
      udp_remove(_upcb);
      _upcb = null;
    }
  }

  static void on_recv(void* arg, udp_pcb* upcb, pbuf* p, const ip_addr_t* addr, u16_t port) {
    unvoid_cast<UDPSocket*>(arg)->on_recv(p, addr, port);
  }
  void on_recv(pbuf* p, const ip_addr_t* addr, u16_t port);

  void send_state();

  void set_recv();

  udp_pcb* upcb() { return _upcb; }

  void queue_packet(Packet* packet) {
    _buffered_bytes += packet->pbuf()->len;
    _packages.append(packet);
  }

  void take_packet() {
    Packet* packet = _packages.remove_first();
    if (packet != null) _buffered_bytes -= packet->pbuf()->len;
    delete packet;
  }

  Packet* next_packet() {
    return _packages.first();
  }

 private:
  Mutex* _mutex;
  udp_pcb* _upcb;
  LinkedFIFO<Packet> _packages;
  int _buffered_bytes;
};

class UDPResourceGroup : public ResourceGroup {
 public:
  TAG(UDPResourceGroup);
  UDPResourceGroup(Process* process, LwIPEventSource* event_source)
      : ResourceGroup(process, event_source)
      , _event_source(event_source) {}

  LwIPEventSource* event_source() { return _event_source; }

 protected:
  virtual void on_unregister_resource(Resource* r) {
    event_source()->call_on_thread([&]() -> Object* {
      r->as<UDPSocket*>()->tear_down();
      return null;
    });
  }

 private:
  LwIPEventSource* _event_source;
};

void UDPSocket::on_recv(pbuf* p, const ip_addr_t* addr, u16_t port) {
  Locker locker(LwIPEventSource::instance()->mutex());

  Packet* packet = _new Packet(p, *addr, port);
  if (packet == null) {
    // TODO(kasper): It would be better to try to pre-allocate the Packet
    // object, so we can push the allocation failure out and not drop
    // received pbufs on the floor.
    pbuf_free(p);
    needs_gc = true;
    return;
  }

  queue_packet(packet);
  set_recv();
  send_state();
}

void UDPSocket::set_recv() {
  if (_buffered_bytes < MAX_QUEUE_SIZE) {
    udp_recv(upcb(), UDPSocket::on_recv, this);
  } else {
    udp_recv(upcb(), null, null);
  }
}

void UDPSocket::send_state() {
  uint32_t state = UDP_WRITE;

  if (!_packages.is_empty()) state |= UDP_READ;
  if (needs_gc) state |= UDP_NEEDS_GC;

  // TODO: Avoid instance usage.
  LwIPEventSource::instance()->set_state(this, state);
}

MODULE_IMPLEMENTATION(udp, MODULE_UDP)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  UDPResourceGroup* resource_group = _new UDPResourceGroup(process, LwIPEventSource::instance());
  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(bind) {
  ARGS(UDPResourceGroup, resource_group, Blob, address, int, port);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  ip_addr_t addr;
  if (address.length() == 4) {
    const uint8_t* a = address.address();
    IP_ADDR4(&addr, a[0], a[1], a[2], a[3]);
  } else {
    OUT_OF_BOUNDS;
  }

  CAPTURE4(
      UDPResourceGroup*, resource_group,
      ip_addr_t&, addr,
      int, port,
      Process*, process);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    Process* process = capture.process;
    udp_pcb* upcb = udp_new();
    if (upcb == null) MALLOC_FAILED;

    err_t err = udp_bind(upcb, &capture.addr, capture.port);
    if (err != ERR_OK) {
      udp_remove(upcb);
      return lwip_error(capture.process, err);
    }

    UDPSocket* socket = _new UDPSocket(capture.resource_group, upcb);
    if (socket == null) {
      udp_remove(upcb);
      MALLOC_FAILED;
    }
    udp_recv(upcb, UDPSocket::on_recv, socket);
    proxy->set_external_address(socket);

    capture.resource_group->register_resource(socket);
    socket->send_state();

    return proxy;
  });
}

PRIMITIVE(connect) {
  ARGS(UDPResourceGroup, resource_group, UDPSocket, socket, Blob, address, int, port);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  ip_addr_t addr;
  if (address.length() == 4) {
    const uint8_t* a = address.address();
    IP_ADDR4(&addr, a[0], a[1], a[2], a[3]);
  } else {
    OUT_OF_BOUNDS;
  }

  CAPTURE4(
      UDPSocket*, socket,
      int, port,
      ip_addr_t&, addr,
      Process*, process);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    err_t err = udp_connect(capture.socket->upcb(), &capture.addr, capture.port);
    if (err != ERR_OK) {
      return lwip_error(capture.process, err);
    }

    return capture.process->program()->null_object();
  });
}

PRIMITIVE(receive)  {
  ARGS(UDPResourceGroup, resource_group, UDPSocket, socket, Object, output);

  CAPTURE3(
      Process*, process,
      UDPSocket*, socket,
      Object*, output);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    Packet* packet = capture.socket->next_packet();
    if (packet == null) return Smi::from(-1);

    ByteArray* address = null;
    if (capture.output->is_array()) {
      // TODO: Support IPv6.
      Error* error = null;
      address = capture.process->allocate_byte_array(4, &error);
      if (address == null) return error;
    }

    pbuf* p = packet->pbuf();
    Error* error = null;
    ByteArray* array = capture.process->allocate_byte_array(p->len, &error);
    if (array == null) return error;

    memcpy(ByteArray::Bytes(array).address(), p->payload, p->len);

    if (capture.output->is_array()) {
      Array* out = Array::cast(capture.output);
      ASSERT(out->length() == 3);
      out->at_put(0, array);
      ip_addr_t addr = packet->addr();
      uint32_t ipv4_address = ip_addr_get_ip4_u32(&addr);
      memcpy(ByteArray::Bytes(address).address(), &ipv4_address, 4);
      out->at_put(1, address);
      out->at_put(2, Smi::from(packet->port()));
    } else {
      capture.output = array;
    }

    capture.socket->take_packet();
    capture.socket->set_recv();
    return capture.output;
  });
}


PRIMITIVE(send) {
  ARGS(UDPResourceGroup, resource_group, UDPSocket, socket, Blob, data, int, from, int, to, Object, address, int, port);

  const uint8* content = data.address();
  if (from < 0 || from > to || to > data.length()) OUT_OF_BOUNDS;

  content += from;
  to -= from;

  ip_addr_t addr;
  if (address != process->program()->null_object()) {
    Blob address_bytes;
    if (!address->byte_content(process->program(), &address_bytes, STRINGS_OR_BYTE_ARRAYS)) WRONG_TYPE;
    if (address_bytes.length() == 4) {
      const uint8_t* a = address_bytes.address();
      IP_ADDR4(&addr, a[0], a[1], a[2], a[3]);
    } else {
      OUT_OF_BOUNDS;
    }
  }

  CAPTURE6(
      UDPSocket*, socket,
      int, to,
      ip_addr_t&, addr,
      Process*, process,
      int, port,
      Object*, address);

  Object* result = resource_group->event_source()->call_on_thread([&]() -> Object* {
    pbuf* p = pbuf_alloc(PBUF_TRANSPORT, capture.to, PBUF_REF);
    if (p == NULL) return Smi::from(capture.to);
    p->payload = const_cast<uint8_t*>(content);

    err_t err;
    if (capture.address->is_byte_array()) {
      err = udp_sendto(capture.socket->upcb(), p, &capture.addr, capture.port);
    } else {
      err = udp_send(capture.socket->upcb(), p);
    }
    pbuf_free(p);

    if (err != ERR_OK) {
      return lwip_error(capture.process, err);
    }

    return Smi::from(capture.to);
  });

  return result;
}

PRIMITIVE(close) {
  ARGS(UDPResourceGroup, resource_group, UDPSocket, socket);

  resource_group->unregister_resource(socket);

  socket_proxy->clear_external_address();

  return process->program()->null_object();
}

PRIMITIVE(error) {
  ARGS(ByteArray, socket_proxy);
  USE(socket_proxy);

  WRONG_TYPE;
}

static Object* get_address_or_error(UDPSocket* socket, Process* process, bool peer) {
  uint32_t address = peer ?
    ip_addr_get_ip4_u32(&socket->upcb()->remote_ip) :
    ip_addr_get_ip4_u32(&socket->upcb()->local_ip);
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
  return process->allocate_string_or_error(buffer, length);
}

PRIMITIVE(get_option) {
  ARGS(UDPResourceGroup, resource_group, UDPSocket, socket, int, option);
  CAPTURE3(UDPSocket*, socket, int, option, Process*, process);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    switch (capture.option) {
      case UDP_PORT:
        return Smi::from(capture.socket->upcb()->local_port);

      case UDP_ADDRESS:
        return get_address_or_error(capture.socket, capture.process, false);

      case UDP_BROADCAST:
        if (capture.socket->upcb()->so_options & SOF_BROADCAST) {
          return capture.process->program()->true_object();
        }
        return capture.process->program()->false_object();

      default:
        return capture.process->program()->unimplemented();
    }
  });
}

PRIMITIVE(set_option) {
  ARGS(UDPResourceGroup, resource_group, UDPSocket, socket, int, option, Object, raw);
  CAPTURE4(
      UDPSocket*, socket,
      int, option,
      Object*, raw,
      Process*, process);

  return resource_group->event_source()->call_on_thread([&]() -> Object* {
    switch (capture.option) {
      case UDP_BROADCAST:
        if (capture.raw == capture.process->program()->true_object()) {
          capture.socket->upcb()->so_options |= SOF_BROADCAST;
        } else if (capture.raw == capture.process->program()->false_object()) {
          capture.socket->upcb()->so_options &= ~SOF_BROADCAST;
        } else {
          return capture.process->program()->wrong_object_type();
        }

      default:
        return capture.process->program()->unimplemented();
    }

    return capture.process->program()->null_object();
  });
}

PRIMITIVE(gc) {
  ARGS(UDPResourceGroup, group);
  Object* do_gc = group->event_source()->call_on_thread([&]() -> Object* {
    bool result = needs_gc;
    needs_gc = false;
    return BOOL(result);
  });
  if (do_gc == process->program()->true_object()) CROSS_PROCESS_GC;
  return process->program()->null_object();
}

} // namespace toit

#endif // defined(TOIT_FREERTOS) || defined(TOIT_USE_LWIP)
