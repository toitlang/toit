// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .tcp as tcp
import tls
import .udp as udp

main:
  socket := tcp.TcpSocket
  socket.close_write
  socket.close_write
  socket.close
  socket.close

  u_socket := udp.Socket
  u_socket.close
  u_socket.close

  tls_socket := tls.Socket.client socket
  tls_socket.close_write
  tls_socket.close_write
  tls_socket.close
  tls_socket.close
