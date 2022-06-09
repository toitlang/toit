// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import reader

import .socket_address

interface Interface:
  tcp_connect host/string port/int -> Socket
  tcp_connect address/SocketAddress -> Socket
  tcp_listen port/int -> ServerSocket

interface Socket implements reader.Reader:
  local_address -> SocketAddress
  peer_address -> SocketAddress

  // TODO(kasper): Remove this.
  set_no_delay enabled/bool -> none

  // Returns true if TCP_NODELAY option is enabled.
  no_delay -> bool

  // Enable or disable TCP_NODELAY option.
  no_delay= value/bool

  read -> ByteArray?
  write data from/int=0 to/int=data.size -> int

  mtu -> int

  // Close the socket for write. The socket will still be able to read incoming data.
  close_write

  // Immediately close the socket and release any resources associated.
  close

interface ServerSocket:
  local_address -> SocketAddress
  accept -> Socket?
  close
