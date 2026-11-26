// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
The network services for sandboxed containers (experimental).

Two variants: $SandboxSocketService (TCP and TLS streams to allowed
  destinations, used by the net.sandbox library) and $SandboxHttpService
  (HTTP requests to allowed destinations, used by the net.sandbox-http
  library). Both are provided by a trusted container (the sandbox network
  provider, services/sandbox_network/ in the SDK sources), not by the
  system process, and only on devices where it is installed. A sandbox
  reaches them when it may use them (`containers.start --services="all"`,
  or the two selectors); the provider checks every destination against its
  network policy (its own configuration, see $network-policy-list), and
  keeps the policy's limits per client container, by the group id the VM
  attaches to each request.

TLS: the provider has no root certificates of its own. A client registers
  the roots it trusts with its session ($ADD-ROOT-INDEX); they are used
  for that client's TLS connections only.

Both variants transfer data in streams with the same calls: $STATE-INDEX,
  $READ-INDEX, $WRITE-INDEX and $CLOSE-WRITE-INDEX on a stream handle. No
  call waits for the network: when a stream has nothing to read, or can't
  take more data, the call says so and the service notifies the stream's
  resource when that changes ($SandboxStream).
*/

import monitor
import tls
import system.services show ServiceSelector ServiceClient ServiceResourceProxy

/** The largest chunk of data a read returns or a write takes. */
CHUNK-SIZE ::= 4096

/** The network policy that allows every destination, without limits. */
NETWORK-ALL ::= "all"
/** The network policy that allows every public address, without limits. */
NETWORK-PUBLIC ::= "public"

MAX-NETWORK-RULES ::= 16
MAX-NETWORK-RULE-SIZE ::= 192
// The limits and the pin setting after the rules (see $network-policy-list).
MAX-NETWORK-SETTINGS ::= 7

/** The most root certificates a client may register, and their total size. */
MAX-CLIENT-ROOTS ::= 4
MAX-CLIENT-ROOT-BYTES ::= 8192

/**
Converts a network policy to the form the provider's policy decision
  takes.

The $policy is one of:
- $NETWORK-ALL ("all"): every destination, private and loopback
  addresses included, without limits.
- $NETWORK-PUBLIC ("public"): every public address (not loopback,
  private, link-local, ...), without limits.
- a list of rules: these destinations, without limits.
- a map with the rules ("allow") and limits.

The keys of the map:
- "allow": a list of rules (strings), see below. Required.
- "connections": concurrent connections (default 2, at most 8).
- "attempts-per-minute": connection attempts (default 20, at most 600).
- "bytes-per-second": the transfer rate in both directions together
  (default 16 KB, 1 KB to 1 MB).
- "bytes-per-day": the bytes transferred in a day (default 10 MB).
- "response-bytes": the largest HTTP response body (default 1 MB).
- "timeout-ms": the longest HTTP request (default 30 s, at most 5 min).
- "require-pins": TLS only to destinations whose rule pins a root
  (default false).
A limit of 0 means no limit.

A rule is `HOST:PORTS`, `HOST:PORTS/PATH`, optionally followed by
  `#PIN`: HOST is a name, a name with a wildcard first label
  (`*.example.com`) or an IPv4 address; PORTS a port or a range
  (`8000-8099`); a PATH prefix restricts HTTP requests and makes the rule
  useless for sockets; PIN is the SHA-256 of a root certificate (64 hex
  digits, of its DER form): TLS connections the rule allows must verify
  with that root (the client still supplies the certificate). Addresses
  that aren't public (loopback, private, link-local) are only reachable
  through a rule that names the address itself.
*/
network-policy-list policy/any -> any:
  if policy is string: return policy
  if policy is List: return [policy, 0, 0, 0, 0, 0, 0, 0]
  map := policy as Map
  return [
    map["allow"],
    map.get "connections" --if-absent=: -1,
    map.get "attempts-per-minute" --if-absent=: -1,
    map.get "bytes-per-second" --if-absent=: -1,
    map.get "bytes-per-day" --if-absent=: -1,
    map.get "response-bytes" --if-absent=: -1,
    map.get "timeout-ms" --if-absent=: -1,
    (map.get "require-pins" --if-absent=: false) ? 1 : 0,
  ]

/**
The bytes of a root certificate for $SandboxNetworkClient.add-root: $root
  is a $tls.RootCertificate, or the certificate's DER or PEM bytes or text.
*/
root-bytes root/any -> ByteArray:
  if root is tls.RootCertificate: root = (root as tls.RootCertificate).raw
  if root is string: return (root as string).to-byte-array
  if root is ByteArray: return root
  throw "WRONG_OBJECT_TYPE"

/** The state of a stream that is still connecting (see $STATE-INDEX). */
STATE-CONNECTING ::= 0
/** The state of a connected stream (see $STATE-INDEX). */
STATE-OPEN ::= 1

/**
The stream calls common to both variants (method indexes).

$STATE-INDEX: `state handle -> int`: $STATE-CONNECTING or $STATE-OPEN;
  throws the stream's error (a short string such as "CONNECT_FAILED").
$READ-INDEX: `read handle received/int -> any`: a byte array of at most
  $CHUNK-SIZE bytes, null at the end of the stream, or 0 if there is
  nothing to read yet; throws the stream's error. $received is the number
  of bytes the client received so far: it acknowledges the previous chunk,
  which is sent again if its reply was lost.
$WRITE-INDEX: `write handle offset/int data/ByteArray -> bool`: false if the
  stream can't take the data yet; throws the stream's error. $offset is
  the position of the data in what the client sent, so a retried write
  isn't taken twice.
$CLOSE-WRITE-INDEX: `close-write handle -> none`: ends the data sent.

All calls may be repeated after a lost reply (QUOTA_EXCEEDED from the
  client's own message quotas): the limits of the services fail with
  NETWORK_QUOTA_EXCEEDED instead.
*/
STATE-INDEX ::= 1
READ-INDEX ::= 2
WRITE-INDEX ::= 3
CLOSE-WRITE-INDEX ::= 4

/**
`add-root total/int offset/int chunk/ByteArray -> int?`: registers a root
  certificate (DER or PEM, $total bytes) with the client's session, sent in
  chunks of at most $CHUNK-SIZE bytes at increasing $offset; returns null
  until the last chunk, then the root's id. At most $MAX-CLIENT-ROOTS roots
  of $MAX-CLIENT-ROOT-BYTES together per client (NETWORK_QUOTA_EXCEEDED);
  they are freed when the client closes. The roots of a client are only
  used for its own TLS connections; identical roots of several clients are
  stored once.
*/
ADD-ROOT-INDEX ::= 6

/**
`stats -> List`: the distinct root certificates the provider stores and
  their bytes, and the open connections. Only for trusted clients (tests and
  measurements).
*/
STATS-INDEX ::= 7

interface SandboxSocketService:
  static SELECTOR ::= ServiceSelector
      --uuid="b8f1d0c4-7e2a-4c55-9a31-5d6e7f8a9b01"
      --major=0
      --minor=1

  /**
  Opens a TCP stream to $host (a name or an IPv4 address) at $port. With
    $tls, the service runs TLS on it and verifies the server's certificate
    for $host against the client's registered roots ($ADD-ROOT-INDEX):
    the ones with the ids in $roots, or all of them if $roots is null.

  Returns the stream handle at once; the connection is made in the
    background (see $STATE-INDEX). Throws NETWORK_DENIED if the network
    policy doesn't allow the destination and NETWORK_QUOTA_EXCEEDED if the
    container has too many connections or made too many attempts.
  */
  connect host/string port/int tls/bool roots/List? -> int
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
    followed: the client gets the 3xx response. An https request verifies
    the server with the client's registered roots ($roots as for
    $SandboxSocketService.connect).
  */
  request method/string url/string headers/List content-length/int? roots/List? -> int
  static REQUEST-INDEX /int ::= 0

  /**
  `response handle -> List?`: null while the response head hasn't arrived,
    then a list of the status code and a flat list of header names and
    values. Throws the stream's error.
  */
  static RESPONSE-INDEX /int ::= 5

// The notifications of a stream. Waiting uses a deadline, not a timeout
// exception, so a wait never ends by unwinding through the monitor.
monitor StreamChanges_:
  count_/int := 0

  notify -> none:
    count_++

  count -> int:
    return count_

  wait-change seen/int deadline-us/int -> none:
    try-await --deadline=deadline-us: count_ != seen

/**
Opens a session with the provider of the service of $selector, waiting up
  to $timeout for it; throws $unavailable if there is none.

Right after the provider was restarted, discovery can still return the
  ended provider (its registration goes when the system process handles its
  end): the open is tried again until the timeout.
*/
open-session selector/ServiceSelector timeout/Duration unavailable/string -> SandboxNetworkClient:
  deadline := Time.monotonic-us + timeout.in-us
  while true:
    remaining := deadline - Time.monotonic-us
    client := SandboxNetworkClient selector
    exception := catch --unwind=(: remaining <= 0 or (it != "NO_SUCH_PROCESS" and it != "Cannot disambiguate")):
      return client.open --timeout=(Duration --us=(max 0 remaining)) --if-absent=: throw unavailable
    sleep --ms=20

/** A client of one of the sandbox network services. */
class SandboxNetworkClient extends ServiceClient:
  /**
  The calls of all clients of this process (for measurements). Every call
    is two messages: the request and the reply.
  */
  static calls/int := 0

  constructor selector/ServiceSelector:
    super selector

  invoke_ index/int arguments/any -> any:
    calls++
    return super index arguments

  connect host/string port/int tls/bool roots/List?=null -> int:
    return invoke_ SandboxSocketService.CONNECT-INDEX [host, port, tls, roots]

  request method/string url/string headers/List content-length/int? roots/List?=null -> int:
    return invoke_ SandboxHttpService.REQUEST-INDEX [method, url, headers, content-length, roots]

  /**
  Registers the root certificate $root (DER or PEM) with this client's
    session and returns its id (see $ADD-ROOT-INDEX).
  */
  add-root root/ByteArray -> int:
    if root.is-empty: throw "INVALID_ARGUMENT"
    result := null
    List.chunk-up 0 root.size CHUNK-SIZE: | from to _ |
      result = invoke_ ADD-ROOT-INDEX [root.size, from, root[from..to].copy]
    return result

  stats -> List:
    return invoke_ STATS-INDEX null

  state handle/int -> int:
    return invoke_ STATE-INDEX handle

  read handle/int received/int -> any:
    return invoke_ READ-INDEX [handle, received]

  write handle/int offset/int data/ByteArray -> bool:
    return invoke_ WRITE-INDEX [handle, offset, data]

  close-write handle/int -> none:
    invoke_ CLOSE-WRITE-INDEX handle

  response handle/int -> List?:
    return invoke_ SandboxHttpService.RESPONSE-INDEX handle

/**
The client side of a stream of a sandbox network service.

Waits for the service's notifications when the stream has nothing to read
  or can't take data. A notification can be lost (the sandbox's mailbox is
  full), so a wait also ends after $POLL-MS and the call is tried again.
  A call whose request or reply doesn't fit the sandbox's message quotas
  (QUOTA_EXCEEDED) is tried again as well, at most $MAX-RETRIES times in a
  row.
*/
class SandboxStream extends ServiceResourceProxy:
  static POLL-MS ::= 500
  static MAX-RETRIES ::= 20
  static CALL-TIMEOUT-MS ::= 30_000
  /** The notifications of all streams of this process (for measurements). */
  static notifications/int := 0
  /** The calls tried again after QUOTA_EXCEEDED (for measurements and tests). */
  static retried/int := 0

  changes_ ::= StreamChanges_
  received_/int := 0
  sent_/int := 0

  constructor client/SandboxNetworkClient handle/int:
    super client handle

  network -> SandboxNetworkClient:
    return client_ as SandboxNetworkClient

  on-notified_ notification/any -> none:
    notifications++
    changes_.notify

  /**
  Calls $block until it returns a value other than 0, false or null, waiting for
    a change of the stream between the calls.
  */
  wait-for [block] -> any:
    retries := 0
    while true:
      if is-closed: throw "ALREADY_CLOSED"
      seen := changes_.count
      result := null
      exception := catch --unwind=(: it != "QUOTA_EXCEEDED" or retries >= MAX-RETRIES):
        result = with-timeout --ms=CALL-TIMEOUT-MS block
      if exception:
        retries++
        retried++
      else:
        retries = 0
      if result != 0 and result != false and result != null: return result
      changes_.wait-change seen (Time.monotonic-us + POLL-MS * 1000)

  /** Waits until the stream is connected; throws its error. */
  wait-connected -> none:
    wait-for: network.state handle_

  /** Reads the next chunk; null at the end of the stream. */
  read-chunk -> ByteArray?:
    result := wait-for:
      chunk := network.read handle_ received_
      chunk == null ? -1 : chunk
    if result == -1: return null
    received_ += result.size
    return result

  /** Sends $data (at most $CHUNK-SIZE bytes). */
  write-chunk data/ByteArray -> none:
    // Sending a large byte array hands its storage over to the receiver,
    // so every attempt sends a copy: a refused or rejected attempt must
    // be repeated with the same bytes.
    wait-for: network.write handle_ sent_ data.copy
    sent_ += data.size

  // Closing the resource is one more call.
  close -> none:
    if not is-closed: SandboxNetworkClient.calls++
    super

  /** Ends the data sent on the stream. */
  end-writes -> none:
    network.close-write handle_
