// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import net.tcp as net
import reader

import .session
import .certificate

/**
TLS Socket implementation that can upgrade a TCP socket to a secure TLS socket.
*/
class Socket extends Session implements net.Socket:
  TLS_HEADER_SIZE_ ::= 29

  socket_/net.Socket

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
  constructor.client .socket_/net.Socket
      --server_name/string?=null
      --certificate/Certificate?=null
      --root_certificates=[]
      --handshake_timeout/Duration=Session.DEFAULT_HANDSHAKE_TIMEOUT:
    super.client socket_ socket_
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
  constructor.server .socket_/net.Socket
      --certificate/Certificate
      --root_certificates=[]
      --handshake_timeout/Duration=Session.DEFAULT_HANDSHAKE_TIMEOUT:
    super.server socket_ socket_
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
    socket_.set_no_delay true
    super --session_state=session_state
    // TODO(anders): Set as before handshake, when state can be read.
    socket_.set_no_delay false

  close:
    super
    socket_.close

  local_address -> net.SocketAddress: return socket_.local_address
  peer_address -> net.SocketAddress: return socket_.peer_address

  set_no_delay value:
    socket_.set_no_delay value

  mtu -> int:
    return socket_.mtu - TLS_HEADER_SIZE_
