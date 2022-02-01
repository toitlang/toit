// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import .udp as udp
import dns_over_udp show *

export DnsException
export DNS_DEFAULT_TIMEOUT
export DNS_RETRY_TIMEOUT

/**
Look up a domain name.

If given a numeric address like 127.0.0.1 it merely parses
  the numbers without a network round trip.

Does not currently cache results, so there is normally a
  network round trip on every use.

By default the server is "8.8.8.8" which is the Google DNS
  service.

Currently only works for IPv4, not IPv6.
*/
dns_lookup -> net.IpAddress
    host/string
    --server/string="8.8.8.8"
    --timeout/Duration=DNS_DEFAULT_TIMEOUT:
  // Call the lookup from dns_over_udp.
  return lookup host --server=server --timeout=timeout:
    udp.Socket
