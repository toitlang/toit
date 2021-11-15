// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .tcp as tcp
import .udp as udp

import .ip_address
import .socket_address

import .impl as impl

export *

open -> Interface:
  return impl.open

// TODO: Should probably be an interface!
abstract class Interface implements udp.Interface tcp.Interface:
  tcp_connect host/string port/int -> tcp.Socket:
    ips := resolve host
    return tcp_connect
      SocketAddress ips[0] port

  abstract resolve host/string -> List
  abstract udp_open -> udp.Socket
  abstract udp_open --port/int? -> udp.Socket
  abstract tcp_connect address/SocketAddress -> tcp.Socket
  abstract tcp_listen port/int -> tcp.ServerSocket
