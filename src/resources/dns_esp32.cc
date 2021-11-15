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

#if defined(TOIT_FREERTOS) || defined(TOIT_USE_LWIP)

#include <lwip/dns.h>
#include <lwip/ip_addr.h>
#include <lwip/ip6_addr.h>

#include "../resource.h"
#include "../objects_inline.h"
#include "../process.h"
#include "../process_group.h"
#include "../vm.h"

#include "../event_sources/lwip_esp32.h"

namespace toit {

class DNSResourceGroup : public ResourceGroup {
 public:
  TAG(DNSResourceGroup);
  DNSResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}
};

class LookupResult : public Resource {
 public:
  TAG(LookupResult);
  explicit LookupResult(ResourceGroup* group) : Resource(group) {}
  ~LookupResult() {
    free(_address);
  }

  bool reserve_memory() {
    _address = unvoid_cast<uint8_t*>(malloc(RESULT_SIZE));
    return _address != null;
  }

  virtual void make_deletable() {
    _delete_me = true;
  }

  err_t err() { return _err; }
  int length() { return _length; }
  uint8_t* address() { return _address; }

  static void on_resolved(const char* hostname, const ip_addr_t* ipaddr, void* arg) {
    LookupResult* result = unvoid_cast<LookupResult*>(arg);

    if (result->_delete_me) {
      delete result;
      return;
    }

    result->on_resolved(hostname, ipaddr);
  }

 private:
  void on_resolved(const char *hostname, const ip_addr_t *ipaddr) {
    if (ipaddr == null) {
      _err = ERR_NAME_LOOKUP_FAILURE;
    } else {
      const uint8_t* data = null;
      uint32_t ipv4_address;
#if LWIP_IPV6 && !defined(TOIT_FREERTOS)
      uint16_t ipv6_address[8];
#endif
      if (IP_IS_V4(ipaddr)) {
        _length = sizeof(ipv4_address);
        data = reinterpret_cast<uint8_t*>(&ipv4_address);
        ipv4_address = ip_addr_get_ip4_u32(ipaddr);
#if LWIP_IPV6 && !defined(TOIT_FREERTOS)
      } else {
        ASSERT(IP_IS_V6(ipaddr));
        _length = sizeof(ipv6_address);
        data = reinterpret_cast<const uint8_t*>(&ipv6_address);
        ipv6_address[0] = IP6_ADDR_BLOCK1(ipaddr);
        ipv6_address[1] = IP6_ADDR_BLOCK2(ipaddr);
        ipv6_address[2] = IP6_ADDR_BLOCK3(ipaddr);
        ipv6_address[3] = IP6_ADDR_BLOCK4(ipaddr);
        ipv6_address[4] = IP6_ADDR_BLOCK5(ipaddr);
        ipv6_address[5] = IP6_ADDR_BLOCK6(ipaddr);
        ipv6_address[6] = IP6_ADDR_BLOCK7(ipaddr);
        ipv6_address[7] = IP6_ADDR_BLOCK8(ipaddr);
#endif
      } else {
        _err = ERR_NAME_LOOKUP_FAILURE;
      }
      if (_err == ERR_OK) {
        ASSERT(_length <= RESULT_SIZE);
        memcpy(_address, data, _length);
      }
    }

    LwIPEventSource::instance()->set_state(this, 1);
  }

  static const int RESULT_SIZE = 16;

  err_t _err = ERR_OK;
  int _length = 0;
  uint8_t* _address = null;
  bool _delete_me = false;
};

MODULE_IMPLEMENTATION(dns, MODULE_DNS)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  DNSResourceGroup* resource_group = _new DNSResourceGroup(process, LwIPEventSource::instance());
  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(lookup) {
  ARGS(DNSResourceGroup, resource_group, cstring, hostname);
  CAPTURE3(
    DNSResourceGroup*, resource_group,
    const char*, hostname,
    Process*, process);

  return LwIPEventSource::instance()->call_on_thread([&]() -> Object *{
    Process* process = capture.process;
    ByteArray* proxy = process->object_heap()->allocate_proxy();
    if (proxy == null) ALLOCATION_FAILED;

    LookupResult* result = _new LookupResult(capture.resource_group);
    if (result == null) MALLOC_FAILED;
    if (!result->reserve_memory()) {
      delete result;
      MALLOC_FAILED;
    }
    proxy->set_external_address(result);

    ip_addr_t address;
    err_t err = dns_gethostbyname(capture.hostname, &address, LookupResult::on_resolved, result);
    if (err == ERR_OK) {
      capture.resource_group->register_resource(result);
      // Address was immediately resolved without a network round trip.
      LookupResult::on_resolved(null, &address, result);
    } else if (err == ERR_INPROGRESS) {
      capture.resource_group->register_resource(result);
    } else if (err == ERR_MEM) {
      // There is no more space for more outstanding DNS requests.  Return null
      // to indicate this.
      delete result;
      return process->program()->null_object();
    } else {
      delete result;
      return lwip_error(process, err);
    }

    return proxy;
  });
}

PRIMITIVE(lookup_result) {
  ARGS(DNSResourceGroup, resource_group, LookupResult, lookup);

  Object* result = null;
  if (lookup->err() != ERR_OK) {
    result = lwip_error(process, lookup->err());
  } else {
    Error* error = null;
    ByteArray* array = process->allocate_byte_array(lookup->length(), &error);
    if (array == null) return error;

    memcpy(ByteArray::Bytes(array).address(), lookup->address(), lookup->length());
    result = array;
  }

  resource_group->unregister_resource(lookup);  // Also deletes lookup.
  lookup_proxy->clear_external_address();

  return result;
}

} // namespace toit

#endif // defined(TOIT_FREERTOS) || defined(TOIT_USE_LWIP)
