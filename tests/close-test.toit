// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .tcp as tcp
import tls
import .udp as udp

main:
  socket := tcp.TcpSocket
  socket.close-write
  socket.close-write
  socket.close
  socket.close

  u-socket := udp.Socket
  u-socket.close
  u-socket.close

  tls-socket := tls.Socket.client socket
  tls-socket.close-write
  tls-socket.close-write
  tls-socket.close
  tls-socket.close
