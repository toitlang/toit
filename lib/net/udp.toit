// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import serialization show serialize deserialize

import .socket_address

interface Interface:
  udp_open -> Socket
  udp_open --port/int? -> Socket

// Datagram to be sent on, or received from, a socket.
class Datagram:
  data/ByteArray := ?
  address/SocketAddress := ?

  constructor .data .address:

  constructor.deserialize bytes/ByteArray:
    values := deserialize bytes
    return Datagram
      values[0]
      SocketAddress.deserialize values[1]

  to_byte_array:
    return serialize [data, address.to_byte_array]

interface Socket:
  local_address -> SocketAddress

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
  write data from=0 to=data.size -> int

  // Close the socket, releasing any resources associated. Calling
  // read on a closed socket will return null.
  close -> none

  // Maximum data size to avoid fragmentation. Data written
  // should not exceed this value.
  mtu -> int

  // Returns true if broadcast is enabled.
  broadcast -> bool

  // Enable or disable broadcast messages.
  broadcast= value/bool
