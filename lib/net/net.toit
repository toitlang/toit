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

interface Interface implements udp.Interface tcp.Interface:
  address -> IpAddress
  resolve host/string -> List

  udp_open -> udp.Socket
  udp_open --port/int? -> udp.Socket

  tcp_connect host/string port/int -> tcp.Socket
  tcp_connect address/SocketAddress -> tcp.Socket
  tcp_listen port/int -> tcp.ServerSocket

  close
