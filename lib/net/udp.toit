// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.tison
import io
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
