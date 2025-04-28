// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import reader

import .socket-address

interface Interface:
  tcp-connect host/string port/int -> Socket
  tcp-connect address/SocketAddress -> Socket
  tcp-listen port/int -> ServerSocket

interface Socket implements reader.Reader:
  local-address -> SocketAddress
  peer-address -> SocketAddress

  // Returns true if TCP_NODELAY option is enabled.
  no-delay -> bool

  // Enable or disable TCP_NODELAY option.
  no-delay= value/bool

  in -> io.CloseableReader
  out -> io.CloseableWriter

  /** Deprecated. Use $(in).read instead. */
  read -> ByteArray?
  /** Deprecated. Use $(out).write or $(out).try-write instead. */
  write data/io.Data from/int=0 to/int=data.byte-size -> int

  mtu -> int

  // Close the socket for write. The socket will still be able to read incoming data.
  /** Deprecated. Use $(out).close instead. */
  close-write

  // Immediately close the socket and release any resources associated.
  close

interface ServerSocket:
  local-address -> SocketAddress
  accept -> Socket?
  close
