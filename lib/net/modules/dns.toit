// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor
import net

dns_lookup hostname:
  id := null
  while not id:
    id = dns_lookup_ dns_resource_group_ hostname
    // In LWIP's implementation of DNS there is a maximum number of
    // outstanding DNS lookups at one time.  If we hit the limit, sleep a
    // little and try later.
    if not id: sleep --ms=10
  state := monitor.ResourceState_ dns_resource_group_ id
  state.wait
  return net.IpAddress (dns_lookup_result_ dns_resource_group_ id)

dns_resource_group_ ::= dns_init_

dns_init_:
  #primitive.dns.init

dns_lookup_ dns_resource_group hostname:
  #primitive.dns.lookup

dns_lookup_result_ dns_resource_group id:
  #primitive.dns.lookup_result
