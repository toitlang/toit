// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
The network services the system offers to sandboxed containers
  (experimental).

Two variants: $SandboxSocketService (TCP and TLS streams to allowed
  destinations, used by the net.sandbox library) and $SandboxHttpService
  (HTTP requests to allowed destinations, used by the net.sandbox-http
  library). Both are only reachable for a sandbox whose launch policy lists
  them (`containers.start --services`) and check every destination against
  the container's network policy (`containers.start --network`, see
  $network-policy-list).

Both variants transfer data in streams with the same calls: $STATE-INDEX,
  $READ-INDEX, $WRITE-INDEX and $CLOSE-WRITE-INDEX on a stream handle. No
  call waits for the network: when a stream has nothing to read, or can't
  take more data, the call says so and the service notifies the stream's
  resource when that changes ($SandboxStream).
*/

import monitor
import system.services show ServiceSelector ServiceClient ServiceResourceProxy

/** The largest chunk of data a read returns or a write takes. */
CHUNK-SIZE ::= 4096

/**
Converts a network policy map to the list form of the launch policy.

The keys:
- "allow": a list of rules (strings), see below. Required.
- "connections": concurrent connections (default 2, at most 8).
- "attempts-per-minute": connection attempts (default 20, at most 600).
- "bytes-per-second": the transfer rate in both directions together
  (default 16 KB, 1 KB to 1 MB).
- "bytes-per-day": the bytes transferred in a day (default 10 MB).
- "response-bytes": the largest HTTP response body (default 1 MB).
- "timeout-ms": the longest HTTP request (default 30 s, at most 5 min).

A rule is `HOST:PORTS` or `HOST:PORTS/PATH`: HOST is a name, a name with
  a wildcard first label (`*.example.com`) or an IPv4 address; PORTS a port
  or a range (`8000-8099`); a PATH prefix restricts HTTP requests and
  makes the rule useless for sockets. Addresses that aren't public
  (loopback, private, link-local) are only reachable through a rule that
  names the address itself.
*/
network-policy-list map/Map -> List:
  return [
    map["allow"],
    map.get "connections" --if-absent=: -1,
    map.get "attempts-per-minute" --if-absent=: -1,
    map.get "bytes-per-second" --if-absent=: -1,
    map.get "bytes-per-day" --if-absent=: -1,
    map.get "response-bytes" --if-absent=: -1,
    map.get "timeout-ms" --if-absent=: -1,
  ]

/** The state of a stream that is still connecting (see $STATE-INDEX). */
STATE-CONNECTING ::= 0
/** The state of a connected stream (see $STATE-INDEX). */
STATE-OPEN ::= 1

/**
The stream calls common to both variants (method indexes).

$STATE-INDEX: `state handle -> int`: $STATE-CONNECTING or $STATE-OPEN;
  throws the stream's error (a short string such as "CONNECT_FAILED").
$READ-INDEX: `read handle -> any`: a byte array of at most $CHUNK-SIZE
  bytes, null at the end of the stream, or 0 if there is nothing to read
  yet; throws the stream's error.
$WRITE-INDEX: `write handle data/ByteArray -> bool`: false if the stream
  can't take the data yet; throws the stream's error.
$CLOSE-WRITE-INDEX: `close-write handle -> none`: ends the data sent.
*/
STATE-INDEX ::= 1
READ-INDEX ::= 2
WRITE-INDEX ::= 3
CLOSE-WRITE-INDEX ::= 4

interface SandboxSocketService:
  static SELECTOR ::= ServiceSelector
      --uuid="b8f1d0c4-7e2a-4c55-9a31-5d6e7f8a9b01"
      --major=0
      --minor=1

  /**
  Opens a TCP stream to $host (a name or an IPv4 address) at $port. With
    $tls, the service runs TLS on it and verifies the server's certificate
    against the system's root certificates and $host.

  Returns the stream handle at once; the connection is made in the
    background (see $STATE-INDEX). Throws NETWORK_DENIED if the network
    policy doesn't allow the destination and QUOTA_EXCEEDED if the
    container has too many connections or made too many attempts.
  */
  connect host/string port/int tls/bool -> int
  static CONNECT-INDEX /int ::= 0

interface SandboxHttpService:
  static SELECTOR ::= ServiceSelector
      --uuid="b8f1d0c4-7e2a-4c55-9a31-5d6e7f8a9b02"
      --major=0
      --minor=1

  /**
  Starts an HTTP/1.1 request with the given $method to the $url (http or
    https) and returns the stream handle.

  The $headers are a flat list of names and values (strings). The service
    sets Host, Connection, Content-Length and Transfer-Encoding itself. If
    $content-length is null, the body is sent chunked; it ends with
    $CLOSE-WRITE-INDEX in either case. The response body is read from the
    stream; the status and headers with $RESPONSE-INDEX. Redirects are not
    followed: the client gets the 3xx response.
  */
  request method/string url/string headers/List content-length/int? -> int
  static REQUEST-INDEX /int ::= 0

  /**
  `response handle -> List?`: null while the response head hasn't arrived,
    then a list of the status code and a flat list of header names and
    values. Throws the stream's error.
  */
  static RESPONSE-INDEX /int ::= 5

/** A client of one of the sandbox network services. */
class SandboxNetworkClient extends ServiceClient:
  constructor selector/ServiceSelector:
    super selector

  connect host/string port/int tls/bool -> int:
    return invoke_ SandboxSocketService.CONNECT-INDEX [host, port, tls]

  request method/string url/string headers/List content-length/int? -> int:
    return invoke_ SandboxHttpService.REQUEST-INDEX [method, url, headers, content-length]

  state handle/int -> int:
    return invoke_ STATE-INDEX handle

  read handle/int -> any:
    return invoke_ READ-INDEX handle

  write handle/int data/ByteArray -> bool:
    return invoke_ WRITE-INDEX [handle, data]

  close-write handle/int -> none:
    invoke_ CLOSE-WRITE-INDEX handle

  response handle/int -> List?:
    return invoke_ SandboxHttpService.RESPONSE-INDEX handle

/**
The client side of a stream of a sandbox network service.

Waits for the service's notifications when the stream has nothing to read
  or can't take data. A notification can be lost (the sandbox's mailbox is
  full), so a wait also ends after $POLL-MS and the call is tried again.
*/
class SandboxStream extends ServiceResourceProxy:
  static POLL-MS ::= 500

  changes_/int := 0
  changed_ ::= monitor.Signal

  constructor client/SandboxNetworkClient handle/int:
    super client handle

  network -> SandboxNetworkClient:
    return client_ as SandboxNetworkClient

  on-notified_ notification/any -> none:
    changes_++
    changed_.raise

  /**
  Calls $block until it returns a value other than 0 or false, waiting for
    a change of the stream between the calls.
  */
  wait-for [block] -> any:
    while true:
      if is-closed: throw "ALREADY_CLOSED"
      seen := changes_
      result := block.call
      if result != 0 and result != false: return result
      catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
        with-timeout --ms=POLL-MS:
          changed_.wait: changes_ != seen

  /** Waits until the stream is connected; throws its error. */
  wait-connected -> none:
    wait-for: network.state handle_

  /** Reads the next chunk; null at the end of the stream. */
  read-chunk -> ByteArray?:
    result := wait-for:
      chunk := network.read handle_
      chunk == null ? -1 : chunk
    return result == -1 ? null : result

  /** Sends $data (at most $CHUNK-SIZE bytes). */
  write-chunk data/ByteArray -> none:
    wait-for: network.write handle_ data

  /** Ends the data sent on the stream. */
  end-writes -> none:
    network.close-write handle_
