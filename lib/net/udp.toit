// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.tison
import io
import .ip-address
import .socket-address

interface Interface:
  udp-open -> Socket
  udp-open --port/int? -> Socket

// Datagram to be sent on, or received from, a socket.
class Datagram:
  data/ByteArray := ?
  address/SocketAddress := ?

  constructor .data .address:

  constructor.deserialize bytes/ByteArray:
    values := tison.decode bytes
    return Datagram
      values[0]
      SocketAddress.deserialize values[1]

  to-byte-array:
    return tison.encode [data, address.to-byte-array]

interface Socket:
  local-address -> SocketAddress

  // Receive datagram from any peer.
  receive -> Datagram

  // Send data to the address of the datagram.
  send datagram/Datagram -> none

  // Connect the socket to a remote peer. The Socket will only receive data
  // from the configured remote peer.
  connect address/SocketAddress -> none

  // Read data from the remote peer.
  read -> ByteArray?

  // Write data to the remote peer.
  write data/io.Data from/int=0 to/int=data.byte-size -> int

  // Close the socket, releasing any resources associated. Calling
  // read on a closed socket will return null.
  close -> none

  // Maximum data size to avoid fragmentation. Data written
  // should not exceed this value.
  mtu -> int

  // Whether broadcast is enabled.
  broadcast -> bool

  // Enable or disable broadcast messages.
  broadcast= value/bool

interface MulticastSocket extends Socket:
  // Whether multicast loopback is enabled.
  multicast-loopback -> bool

  // Enable or disable multicast loopback.
  multicast-loopback= value/bool

  // Returns the multicast TTL.
  multicast-ttl -> int

  // Sets the multicast TTL.
  multicast-ttl= value/int

  // Whether reuse address is enabled.
  reuse-address -> bool

  // Enable or disable reuse address.
  reuse-address= value/bool

  // Whether reuse port is enabled.
  reuse-port -> bool

  // Enable or disable reuse port.
  reuse-port= value/bool

  /**
  Joins the multicast group identified by $address.
  After this call, the socket will receive messages sent to the given
    multicast group.
  */
  multicast-add-membership address/IpAddress

  /**
  Leaves the multicast group identified by $address.
  After this call, the socket will no longer receive messages sent
    to the given multicast group.
  */
  multicast-leave-membership address/IpAddress

  /**
  Returns the IP address of the interface used for outgoing multicast
    packets.
  */
  multicast-interface -> IpAddress

  /**
  Sets the interface used for outgoing multicast packets to the
    given $address.

  This corresponds to the IP_MULTICAST_IF socket option. When sending
    to a multicast address, the OS needs to know which network interface
    to use. If not set, the OS picks a default interface which may not
    be the correct one (e.g. on macOS, a plain socket may fail to send
    multicast without this being configured).

  Common values:
  - "127.0.0.1" for loopback (useful in tests).
  - "0.0.0.0" to let the OS pick a default interface.
  */
  multicast-interface= address/IpAddress

interface MulticastInterface:
  /**
  Opens a UDP socket configured for multicast.

  The returned socket is ready for multicast communication but does not
    automatically join any group. Use $MulticastSocket.multicast-add-membership
    to join a group for receiving, or simply send to a multicast address for
    sending.

  The $port is the local port to bind to. If null, the OS picks an
    ephemeral port (typical for send-only sockets).
  The $if-addr is the IP address of the interface to use for outgoing
    multicast. If null, the OS picks a default interface.
  If $reuse-address is true (the default), the SO_REUSEADDR option is set.
  If $reuse-port is true (not default), the SO_REUSEPORT option is set
    (if supported by the platform).
  If $loopback is true (the default), multicast packets sent from this
    socket are also delivered to receivers on the same host.
  The $ttl is the multicast time-to-live (default 1, meaning
    link-local only).
  */
  udp-open-multicast -> MulticastSocket
      --port/int?=null
      --if-addr/IpAddress?=null
      --reuse-address/bool=true
      --reuse-port/bool=false
      --loopback/bool=true
      --ttl/int=1

  /**
  Deprecated. Use $(udp-open-multicast --port --if-addr --reuse-address --reuse-port --loopback --ttl)
    followed by $MulticastSocket.multicast-add-membership instead.

  Opens a UDP multicast socket, binds to $port, and automatically joins
    the multicast group $address.
  */
  udp-open-multicast -> MulticastSocket
      address/IpAddress
      port/int
      --if-addr/IpAddress?=null
      --reuse-address/bool=true
      --reuse-port/bool=false
      --loopback/bool=true
      --ttl/int=1
