// Copyright (C) 2026 Toit contributors.
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

/**
The part of the sandbox network provider (experimental) that both
  variants share: connections that are made, read and written in the
  background, so that no request of a sandbox waits for the network in one
  of the provider's RPC tasks; the network policies of the clients'
  containers; the clients' root certificates.

The provider is a trusted container (see main.toit). It learns the group
  id of every request from the VM (the `--gid` of a service call, which the
  sender can't choose; group ids are never reused), and asks the system
  process for the network policy of that group once ($SandboxNetworkCore.grant).

A connection is a notifiable service resource: it is closed (and its
  socket with it) when the client closes it, closes its service client, or
  ends (stopped, killed or evicted), through the services framework, which
  watches the client's process.

Bounds per connection: three chunks of $CHUNK-SIZE (one read ahead, one
  handed out and not yet acknowledged, one to write), three tasks, the
  socket (and with TLS, the TLS session). Per container: the policy's
  connection limit. In total: $SandboxNetworkCore.MAX-CONNECTIONS
  connections and one TLS handshake at a time; these bounds stay with every
  policy, also "all".
*/

import monitor
import net
import tls
import system.containers
import rpc.broker
import system.services show ServiceProvider ServiceHandler ServiceResource
import system.api.sandbox-network show CHUNK-SIZE STATE-CONNECTING STATE-OPEN
    STATE-INDEX READ-INDEX WRITE-INDEX CLOSE-WRITE-INDEX ADD-ROOT-INDEX STATS-INDEX

import .policy
import .roots

/** What the services of both variants share. */
class SandboxNetworkCore:
  /** Connections of all clients together. */
  static MAX-CONNECTIONS ::= 8
  /** Containers whose policy is kept when they have no connection. */
  static MAX-CACHED-GRANTS ::= 32
  static CONNECT-TIMEOUT-MS ::= 10_000
  static HANDSHAKE-TIMEOUT-MS ::= 15_000

  network_/net.Client? := null
  connections_/int := 0
  // TLS handshakes need the most memory, so they take turns.
  handshakes_ ::= monitor.Semaphore --count=1
  // The policies by group id, false for a group without one, most recently
  // used last. A grant also holds the limiter state of its container, so it
  // stays while the container has connections.
  grants_/Map ::= {:}
  // Looks up the network policy of a group (the system process).
  policy-lookup_/Lambda

  roots ::= RootStore
  client-roots_/Map ::= {:}  // Map<int, ClientRoots>, by client id.

  constructor --policy-lookup/Lambda=(:: | gid | containers.network-policy --gid=gid):
    policy-lookup_ = policy-lookup

  /**
  The network policy of the container of $gid; throws NETWORK_DENIED if it
    has none. Asks the system process once per container (while the
    container's grant is cached).
  */
  grant gid/int -> NetworkGrant:
    result := grants_.get gid
    if result != null:
      // Most recently used last.
      grants_.remove gid
      grants_[gid] = result
    else:
      policy := policy-lookup_.call gid
      result = false
      if policy != null:
        catch: result = NetworkGrant policy
      evict-grants_
      grants_[gid] = result
    if result is not NetworkGrant: throw "NETWORK_DENIED"
    return result

  evict-grants_ -> none:
    if grants_.size < MAX-CACHED-GRANTS: return
    victim := null
    grants_.do: | gid grant |
      if not victim and (grant is not NetworkGrant or grant.connections == 0): victim = gid
    if victim != null: grants_.remove victim

  /** The roots of the client with the given id. */
  roots-of client/int -> ClientRoots:
    return client-roots_.get client --init=: ClientRoots roots

  client-closed client/int -> none:
    client-roots_.get client --if-present=: | r/ClientRoots |
      r.release
      client-roots_.remove client

  network -> net.Client:
    if not network_: network_ = net.open
    return network_

  /**
  Resolves $host (or parses it, if it is an IPv4 address) and returns the
    first address the $grant allows at $port. Throws CONNECT_FAILED,
    whether the name can't be resolved or resolves to addresses that are
    not allowed: the sandbox doesn't learn which internal names exist. An
    address the client gave that isn't allowed is NETWORK_DENIED.
  */
  resolve host/string port/int grant/NetworkGrant -> net.IpAddress:
    literal := parse-ipv4 host
    if literal:
      if not grant.address-allowed literal port: throw "NETWORK_DENIED"
      return net.IpAddress literal
    candidates/List? := null
    catch: candidates = network.resolve host
    if not candidates: throw "CONNECT_FAILED"
    candidates.do: | address/net.IpAddress |
      if grant.address-allowed address.to-byte-array port: return address
    throw "CONNECT_FAILED"

  open-connection grant/NetworkGrant -> none:
    if connections_ >= MAX-CONNECTIONS: throw "NETWORK_QUOTA_EXCEEDED"
    grant.open-connection
    connections_++

  close-connection grant/NetworkGrant -> none:
    connections_--
    grant.close-connection

  /** Runs $block (a TLS handshake) when no other handshake runs. */
  handshake [block] -> none:
    handshakes_.down
    try:
      with-timeout --ms=HANDSHAKE-TIMEOUT-MS block
    finally:
      handshakes_.up

  /**
  The roots a TLS connection of $client may verify with: the client's roots
    with the given $ids (all if null), restricted to the ones the policy
    pins for the destination. Throws NETWORK_DENIED if the policy requires a
    pin and no rule for the destination has one.
  */
  tls-roots client/int ids/List? grant/NetworkGrant host/string port/int --path/string? -> List:
    pins := grant.pins-for host port --path=path
    if pins and pins.is-empty: throw "NETWORK_DENIED"
    selected := (roots-of client).select ids
    if not pins: return selected
    return selected.filter: | entry/RootEntry | pins.contains entry.hash

  stats -> List:
    return roots.stats + [connections_]

/**
A stream to a destination, made and transferred by tasks of the provider.
  Subclasses frame the data (HTTP).
*/
class SandboxConnection extends ServiceResource:
  core/SandboxNetworkCore
  grant/NetworkGrant
  host/string
  port/int
  use-tls/bool
  roots_/List                  // The RootEntry objects for TLS.

  socket_ := null              // A tcp.Socket or tls.Socket.
  connected_/bool := false
  error_/string? := null
  closed_/bool := false
  in_/ByteArray? := null       // Read ahead, not yet taken by the client.
  unacked_/ByteArray? := null  // Handed out, not yet acknowledged.
  acked_/int := 0              // Bytes the client acknowledged receiving.
  accepted_/int := 0           // Bytes taken from the client.
  in-ended_/bool := false
  out_/ByteArray? := null      // Taken from the client, not yet written.
  out-closing_/bool := false
  client-waits_/bool := false  // The client waits for a notification.
  signal_ ::= monitor.Signal   // Changes for the tasks.
  tasks_/List := []

  /**
  Starts connecting. The caller checked the destination with
    $NetworkGrant.allows and took the connection from the limits (see
    $SandboxNetworkProvider.open-stream_).
  */
  constructor provider/ServiceProvider client/int .core .grant .host .port .use-tls
      --roots/List=[]
      --deadline-ms/int?=null:
    roots_ = roots
    super provider client --notifiable
    tasks_.add (task --background:: run_)
    if deadline-ms:
      tasks_.add (task --background::
        sleep --ms=deadline-ms
        fail_ "TIMEOUT")

  run_ -> none:
    exception := catch:
      // Without a root the verification can't succeed (the provider has
      // none of its own).
      if use-tls and roots_.is-empty: throw "TLS_FAILED"
      address := core.resolve host port grant
      raw := null
      connect-error := catch:
        with-timeout --ms=SandboxNetworkCore.CONNECT-TIMEOUT-MS:
          raw = core.network.tcp-connect (net.SocketAddress address port)
      if connect-error: throw "CONNECT_FAILED"
      // The client's writes are chunks already; don't delay them.
      raw.no-delay = true
      socket_ = raw
      if use-tls:
        certificates := roots_.map: | entry/RootEntry | entry.parsed
        secure := tls.Socket.client raw --server-name=host --root-certificates=certificates
        socket_ = secure
        handshake-error := catch: core.handshake: secure.handshake
        if handshake-error: throw "TLS_FAILED"
      connected_ = true
      changed_
      tasks_.add (task --background:: writer_)
      reader_
    if exception: fail_ exception

  // Writes what the client gives (framed by $write-data_).
  writer_ -> none:
    exception := catch:
      write-head_
      while true:
        signal_.wait: out_ != null or out-closing_ or closed_
        if closed_: return
        data := out_
        if not data:
          finish-data_
          return
        throttle_ data.size
        write-data_ data
        out_ = null
        changed_
    if exception: fail_ exception

  /** Reads from the socket and hands the data to the client ($deliver_). */
  reader_ -> none:
    while true:
      data := socket_.in.read --max-size=CHUNK-SIZE
      if not data:
        end_
        return
      deliver_ data

  /**
  Hands $data to the client: appended to the chunk the client hasn't taken
    yet if both fit in a chunk, so a client that is slower than the network
    takes full chunks; otherwise when the client took the previous chunk.
  */
  deliver_ data/ByteArray -> none:
    throttle_ data.size
    signal_.wait: closed_ or in_ == null or in_.size + data.size <= CHUNK-SIZE
    if closed_: return
    in_ = in_ ? in_ + data : data
    changed_

  /** Ends the data for the client. */
  end_ -> none:
    in-ended_ = true
    changed_

  throttle_ size/int -> none:
    delay := grant.take-bytes size
    if delay > 0: sleep --ms=delay

  write-head_ -> none:
  write-data_ data/ByteArray -> none:
    socket_.out.write data
  finish-data_ -> none:
    socket_.out.close

  /** Notifies the client if it waits for a change. */
  changed_ -> none:
    signal_.raise
    if client-waits_ and not is-closed:
      client-waits_ = false
      catch: notify_ 1

  /**
  Fails the stream with an error for the client: one of the short errors
    of the services, any other exception becomes CONNECTION_FAILED (after
    the connection was made) or CONNECT_FAILED.
  */
  fail_ exception -> none:
    if error_ or closed_: return
    if exception == DEADLINE-EXCEEDED-ERROR: exception = "TIMEOUT"
    if not KNOWN-ERRORS_.contains exception:
      // The details are for the console, not for the sandbox. A sandbox
      // causes at most one line per connection attempt.
      catch: print_ "[sandbox network: $host:$port: $exception]"
      exception = connected_ ? "CONNECTION_FAILED" : "CONNECT_FAILED"
    error_ = exception
    close-socket_
    changed_

  static KNOWN-ERRORS_ ::= {
    "NETWORK_DENIED", "NETWORK_QUOTA_EXCEEDED", "CONNECT_FAILED", "TLS_FAILED",
    "TIMEOUT", "CONNECTION_FAILED", "RESPONSE_TOO_LARGE", "HTTP_PROTOCOL_ERROR",
    "INVALID_ARGUMENT",
  }

  close-socket_ -> none:
    socket := socket_
    socket_ = null
    if socket: catch: socket.close

  on-closed -> none:
    if closed_: return
    closed_ = true
    signal_.raise
    close-socket_
    // A task may be the caller (a failing request closes from the task).
    current := Task.current
    tasks_.do: | t/Task | if t != current: t.cancel
    core.close-connection grant

  // The stream calls of the clients.

  state -> int:
    if error_: throw error_
    if connected_: return STATE-OPEN
    client-waits_ = true
    return STATE-CONNECTING

  /**
  Returns the next chunk for a client that has received $received bytes.

  A reply can be lost (refused by the client's full mailbox; the client
    gets QUOTA_EXCEEDED instead), so the chunk handed out stays until the
    next read acknowledges it, and a read that doesn't is answered with
    the same chunk again.
  */
  read received/int -> any:
    if unacked_:
      if received == acked_: return unacked_.copy
      if received != acked_ + unacked_.size: throw "INVALID_ARGUMENT"
      unacked_ = null
      acked_ = received
    else if received != acked_:
      throw "INVALID_ARGUMENT"
    if in_:
      unacked_ = in_
      in_ = null
      signal_.raise
      // Sending a large byte array hands its storage over to the receiver,
      // so the reply gets a copy.
      return unacked_.copy
    if in-ended_: return null
    if error_: throw error_
    client-waits_ = true
    return 0

  /**
  Takes $data, which starts at byte $offset of what the client sent.
    A chunk that was taken already (the client retries after a lost reply)
    is not taken again.
  */
  write offset/int data/ByteArray -> bool:
    if error_: throw error_
    if offset + data.size <= accepted_ and offset >= 0: return true
    if offset != accepted_ or out-closing_ or data.size > CHUNK-SIZE:
      throw "INVALID_ARGUMENT"
    if out_:
      client-waits_ = true
      return false
    out_ = data
    accepted_ += data.size
    signal_.raise
    return true

  close-write -> none:
    if error_: throw error_
    out-closing_ = true
    signal_.raise

/**
A provider of a sandbox network service: handles the stream calls; the
  variants add the calls that open streams.
*/
abstract class SandboxNetworkProvider extends ServiceProvider implements ServiceHandler:
  core/SandboxNetworkCore

  constructor name/string .core:
    super name --major=0 --minor=1

  // The provider exists for sandboxes; which of them may use it is up to
  // the service list (or the network policy) of their containers.
  accepts-untrusted-clients -> bool:
    return true

  on-closed client/int -> none:
    core.client-closed client

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == READ-INDEX:
      if arguments is not List or arguments.size != 2 or arguments[1] is not int:
        throw "WRONG_OBJECT_TYPE"
      return (stream_ client arguments[0]).read arguments[1]
    if index == WRITE-INDEX:
      if arguments is not List or arguments.size != 3 or arguments[1] is not int
          or arguments[2] is not ByteArray:
        throw "WRONG_OBJECT_TYPE"
      return (stream_ client arguments[0]).write arguments[1] arguments[2]
    if index == STATE-INDEX: return (stream_ client arguments).state
    if index == CLOSE-WRITE-INDEX: return (stream_ client arguments).close-write
    if index == ADD-ROOT-INDEX:
      if arguments is not List or arguments.size != 3 or arguments[0] is not int
          or arguments[1] is not int or arguments[2] is not ByteArray:
        throw "WRONG_OBJECT_TYPE"
      return (core.roots-of client).add arguments[0] arguments[1] arguments[2]
    if index == STATS-INDEX:
      // Which roots other clients registered is no business of a sandbox.
      if broker.RpcBroker.is-untrusted_ (pid --client=client): throw "PERMISSION_DENIED"
      return core.stats
    return handle-open index arguments --gid=gid --client=client

  abstract handle-open index/int arguments/any --gid/int --client/int -> any

  /**
  Takes a connection from the limits of the $grant and returns the handle
    of the stream that $create makes (a $SandboxConnection).
  */
  open-stream_ grant/NetworkGrant [create] -> int:
    core.open-connection grant
    stream/SandboxConnection? := null
    try:
      stream = create.call
      return stream.serialize-for-rpc
    finally:
      if not stream: core.close-connection grant

  stream_ client/int handle/any -> SandboxConnection:
    if handle is not int: throw "WRONG_OBJECT_TYPE"
    result := resource client handle
    if result is not SandboxConnection: throw "INVALID_ARGUMENT"
    return result as SandboxConnection
