// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
TCP and TLS sockets for sandboxed containers (experimental).

A sandbox can't use the network primitives. This library gets its sockets
  from the system's sandbox socket service, which connects only to the
  destinations of the container's network policy and runs TLS itself (with
  the system's root certificates). The container must be started with the
  service on its service list and a network policy:

```
containers.start id --untrusted
    --services=[SandboxSocketService.SELECTOR]
    --network={"allow": ["api.example.com:443"]}
```

The sockets implement $tcp.Socket, so code written for sockets works on
  them, for example the HTTP client of the http package:

```
import http
import net.sandbox

main:
  network := sandbox.open
  // Plain HTTP over a service socket.
  client := http.Client network
  // HTTPS: the service runs TLS, the http library only HTTP.
  client = http.Client network.with-tls
  response := client.get --uri="http://api.example.com:443/status"
```
*/

import io
import net
import net.tcp
import system.api.sandbox-network show *

service_/SandboxNetworkClient? ::= (SandboxNetworkClient SandboxSocketService.SELECTOR).open
    --if-absent=: null

/**
Opens the sandbox network. Throws if the container may not use the
  sandbox socket service.
*/
open -> SandboxNetwork:
  client := service_
  if not client: throw "Sandbox network unavailable"
  return SandboxNetwork.internal_ client --tls=false

/**
A network interface for TCP connections through the sandbox socket
  service. Without TLS, $tcp-connect opens plain TCP connections; the
  interface returned by $with-tls opens TLS connections instead.
*/
class SandboxNetwork implements tcp.Interface:
  client_/SandboxNetworkClient
  tls_/bool

  constructor.internal_ .client_ --tls/bool:
    tls_ = tls

  /**
  Returns an interface whose $tcp-connect opens TLS connections, run by
    the service, which verifies the server's certificate for the host name
    against the system's root certificates.
  */
  with-tls -> SandboxNetwork:
    return SandboxNetwork.internal_ client_ --tls

  /**
  Connects to $host (a name or an IPv4 address) at $port.

  Throws NETWORK_DENIED if the container's network policy doesn't allow
    it, QUOTA_EXCEEDED if the container has too many connections or made
    too many attempts, CONNECT_FAILED or TLS_FAILED if the connection
    can't be made.
  */
  tcp-connect host/string port/int -> SandboxSocket:
    handle := client_.connect host port tls_
    socket := SandboxSocket.internal_ client_ handle --peer=(net.SocketAddress (ip-of_ host) port)
    try:
      socket.wait-connected
      return socket
    finally: | is-exception _ |
      if is-exception: socket.close

  tcp-connect address/net.SocketAddress -> SandboxSocket:
    return tcp-connect address.ip.stringify address.port

  /** Sandboxes can't listen. */
  tcp-listen port/int -> tcp.ServerSocket:
    throw "UNSUPPORTED"

  static ip-of_ host/string -> net.IpAddress:
    catch: return net.IpAddress.parse host
    return net.IpAddress #[0, 0, 0, 0]

/**
A TCP socket of the sandbox socket service.

It doesn't reveal addresses: the local address is 0.0.0.0:0 and the peer
  address has the address of the host if it was given as an address,
  0.0.0.0 otherwise.
*/
class SandboxSocket extends SandboxStream with io.CloseableInMixin io.CloseableOutMixin implements tcp.Socket:
  peer-address/net.SocketAddress

  constructor.internal_ client/SandboxNetworkClient handle/int --peer/net.SocketAddress:
    peer-address = peer
    super client handle

  local-address -> net.SocketAddress:
    return net.SocketAddress (net.IpAddress #[0, 0, 0, 0]) 0

  no-delay -> bool:
    return true

  no-delay= value/bool -> none:

  mtu -> int:
    return CHUNK-SIZE

  read -> ByteArray?:
    return read_

  read_ -> ByteArray?:
    if is-closed: return null
    return read-chunk

  write data/io.Data from/int=0 to/int=data.byte-size -> int:
    return try-write_ data from to

  try-write_ data/io.Data from/int to/int -> int:
    size := min (to - from) CHUNK-SIZE
    if size == 0: return 0
    chunk := ByteArray size
    data.write-to-byte-array chunk --at=0 from (from + size)
    write-chunk chunk
    return size

  close-write -> none:
    out.close

  close-writer_ -> none:
    if not is-closed: end-writes

  close-reader_ -> none:

  close -> none:
    mark-reader-closed_
    mark-writer-closed_
    super
