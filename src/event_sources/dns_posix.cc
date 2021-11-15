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

#if defined(TOIT_LINUX) || defined(TOIT_BSD)

#include <errno.h>
#include <netdb.h>

#include "../objects_inline.h"

#include "dns_posix.h"

namespace toit {

DNSEventSource* DNSEventSource::_instance = null;

DNSEventSource::DNSEventSource()
    : EventSource("DNS")
    , Thread("DNS")
    , _stop(false)
    , _lookup_requests_changed(OS::allocate_condition_variable(mutex())) {
  ASSERT(_instance == null);
  _instance = this;

  spawn();
}

DNSEventSource::~DNSEventSource() {
  {
    Locker locker(mutex());
    _stop = true;
    OS::signal(_lookup_requests_changed);
  }

  join();

  OS::dispose(_lookup_requests_changed);

  _instance = null;
}

void DNSEventSource::on_register_resource(Locker& locker, Resource* r) {
  OS::signal(_lookup_requests_changed);
}

void DNSEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  OS::signal(_lookup_requests_changed);
  auto request = static_cast<DNSLookupRequest*>(r);
  if (request->address() != null) return;
  while (!request->is_done()) {
    OS::wait(_lookup_requests_changed);
  }
}

void DNSEventSource::entry() {
  Locker locker(mutex());

  while (!_stop) {
    if (resources().is_empty() || static_cast<DNSLookupRequest*>(resources().first())->is_done()) {
      OS::wait(_lookup_requests_changed);
      continue;
    }

    auto request = static_cast<DNSLookupRequest*>(resources().first());
    auto address = request->address();
    request->set_address(null);

    // Leave lock while handling lookup.
    const struct hostent* server;
    { Unlocker unlock(locker);
      server = gethostbyname(char_cast(address));
    }

    free(address);
    request->mark_done();
    OS::signal(_lookup_requests_changed);

    if (server == null) {
      ASSERT(h_errno > 0);
      request->set_error(h_errno);
    } else {
      request->set_length(server->h_length);
      uint8_t* address = unvoid_cast<uint8_t*>(malloc(server->h_length));
      memcpy(address, server->h_addr_list[0], server->h_length);
      request->set_address(address);
    }

    dispatch(locker, request, 0);
  }
}

} // namespace toit

#endif // TOIT_LINUX
