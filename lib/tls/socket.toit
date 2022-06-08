// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import net.tcp
import reader

import .session
import .certificate

/**
TLS Socket implementation that can upgrade a TCP socket to a secure TLS socket.
*/
class Socket implements tcp.Socket:
  TLS_HEADER_SIZE_ ::= 29

  socket_/tcp.Socket
  session_/Session

  /**
  Creates a new TLS socket for a client-side TCP socket.

  If $server_name is provided, it will validate the peer certificate against that. If
    the $server_name is omitted, it will skip verification.
  The $root_certificates are used to validate the peer certificate.
  If $certificate is given, the certificate is used by the server to validate the
    authority of the client. This is not done using e.g. HTTPS communication.
  The handshake routine requires at most $handshake_timeout between each step
    in the handshake process.
  */
  constructor.client .socket_/tcp.Socket
      --server_name/string?=null
      --certificate/Certificate?=null
      --root_certificates=[]
      --handshake_timeout/Duration=Session.DEFAULT_HANDSHAKE_TIMEOUT:
    session_ = Session.client socket_ socket_
      --server_name=server_name
      --certificate=certificate
      --root_certificates=root_certificates
      --handshake_timeout=handshake_timeout

  /**
  Creates a new TLS socket for a server-side TCP socket.

  The $root_certificates are used to validate the peer certificate if present.
  If $certificate is used as the authority of the server.
  The handshake routine requires at most $handshake_timeout between each step
    in the handshake process.
  */
  constructor.server .socket_/tcp.Socket
      --certificate/Certificate
      --root_certificates=[]
      --handshake_timeout/Duration=Session.DEFAULT_HANDSHAKE_TIMEOUT:
    session_ = Session.server socket_ socket_
      --certificate=certificate
      --root_certificates=root_certificates
      --handshake_timeout=handshake_timeout

  /**
  Explicitly completes the handshake step.

  This method will automatically be called by read and write if the handshake
    is not completed yet.

  If $session_state is given, the handshake operation will use it to resume the TLS
    session from the previous stored session state. This can greatly improve the
    duration of a complete TLS handshake. If the session state is invalid, the
    operation will fall back to performing the full handshake.
  */
  handshake --session_state/ByteArray?=null -> none:
    no_delay ::= socket_.no_delay
    socket_.no_delay = true
    session_.handshake --session_state=session_state
    socket_.no_delay = no_delay

  /**
  Gets the session state, a ByteArray that can be used to resume
    a TLS session at a later point.

  The session can be read at any point after a handshake, but before the session
    is closed.
  */
  session_state -> ByteArray:
    return session_.session_state

  read -> ByteArray?:
    return session_.read

  write data from/int=0 to/int=data.size -> int:
    return session_.write data from to

  close -> none:
    session_.close
    socket_.close

  close_write -> none:
    session_.close_write
    socket_.close_write

  local_address -> net.SocketAddress:
    return socket_.local_address

  peer_address -> net.SocketAddress:
    return socket_.peer_address

  // TODO(kasper): Remove this.
  set_no_delay enabled/bool -> none:
    no_delay = enabled

  no_delay -> bool:
    return socket_.no_delay

  no_delay= value/bool:
    socket_.no_delay = value

  mtu -> int:
    return socket_.mtu - TLS_HEADER_SIZE_
