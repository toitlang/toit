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

#if (defined(TOIT_LINUX) || defined(TOIT_BSD)) && !defined(TOIT_USE_LWIP)

#include <errno.h>
#include <netdb.h>

#include "../resource.h"
#include "../objects.h"
#include "../objects_inline.h"
#include "../os.h"
#include "../primitive.h"
#include "../process_group.h"
#include "../process.h"
#include "../vm.h"

#include "../event_sources/dns_posix.h"

namespace toit {

class DNSResourceGroup : public ResourceGroup {
 public:
  TAG(DNSResourceGroup);
  DNSResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}

  DNSLookupRequest* lookup(char* address) {
    DNSLookupRequest* request = _new DNSLookupRequest(this, unsigned_cast(address));
    register_resource(request);
    return request;
  }

  uint32_t on_event(Resource* resource, word data, uint32_t state) {
    return state + 1;
  }
};

MODULE_IMPLEMENTATION(dns, MODULE_DNS)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  DNSResourceGroup* resource_group = _new DNSResourceGroup(process, DNSEventSource::instance());
  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(lookup) {
  ARGS(DNSResourceGroup, resource_group, String, hostname);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;
  // NOTE: The contract is lookup will deal with freeing.
  char* name = hostname->cstr_dup();
  proxy->set_external_address(resource_group->lookup(name));
  return proxy;
}

PRIMITIVE(lookup_result) {
  ARGS(DNSResourceGroup, resource_group, DNSLookupRequest, lookup);

  Object* result = null;

  if (lookup->error() != 0) {
    result = Primitive::os_error(lookup->error(), process);
  } else {
    Error* error = null;
    ByteArray* array = process->allocate_byte_array(lookup->length(), &error);
    if (array == null) return error;
    memcpy(ByteArray::Bytes(array).address(), lookup->address(), lookup->length());
    result = array;
  }

  resource_group->unregister_resource(lookup);

  return result;
}

} // namespace toit

#endif // (defined(TOIT_LINUX) || defined(TOIT_BSD)) && !defined(TOIT_USE_LWIP)
