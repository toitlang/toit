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
  static TLS-HEADER-SIZE_ ::= 29

  socket_/tcp.Socket
  session_/Session

  /**
  Creates a new TLS socket for a client-side TCP socket.

  If $server-name is provided, it will validate the peer certificate against that. If
    the $server-name is omitted, it will skip verification.
  The $root-certificates are used to validate the peer certificate.
  If $certificate is given, the certificate is used by the server to validate the
    authority of the client. This is not done using e.g. HTTPS communication.
  The handshake routine requires at most $handshake-timeout between each step
    in the handshake process.
  */
  constructor.client .socket_/tcp.Socket
      --server-name/string?=null
      --certificate/Certificate?=null
      --root-certificates=[]
      --handshake-timeout/Duration=Session.DEFAULT-HANDSHAKE-TIMEOUT:
    session_ = Session.client socket_ socket_
      --server-name=server-name
      --certificate=certificate
      --root-certificates=root-certificates
      --handshake-timeout=handshake-timeout

  /**
  Creates a new TLS socket for a server-side TCP socket.

  The $root-certificates are used to validate the peer certificate if present.
  If $certificate is used as the authority of the server.
  The handshake routine requires at most $handshake-timeout between each step
    in the handshake process.
  */
  constructor.server .socket_/tcp.Socket
      --certificate/Certificate
      --root-certificates=[]
      --handshake-timeout/Duration=Session.DEFAULT-HANDSHAKE-TIMEOUT:
    session_ = Session.server socket_ socket_
      --certificate=certificate
      --root-certificates=root-certificates
      --handshake-timeout=handshake-timeout

  /**
  Explicitly completes the handshake step.

  This method will automatically be called by read and write if the handshake
    is not completed yet.
  */
  handshake -> none:
    no-delay ::= socket_.no-delay
    socket_.no-delay = true
    session_.handshake
    socket_.no-delay = no-delay

  /**
  Gets the session state, a ByteArray that can be used to resume
    a TLS session at a later point.

  The session can be read at any point after a handshake, but before the session
    is closed.
  */
  session-state -> ByteArray?:
    return session_.session-state

  /**
  Set the state from a previous connection to the same TLS server.
  This can dramatically speed up the handshake process.
  Note that we don't currently have the ability to fall back from a resumed
    session to a full handshake, so if the session is invalid, or the server has
    forgotten about it, the handshake will fail.
  */
  session-state= state/ByteArray:
    m := session_.mode
    if m != SESSION-MODE-NONE:
      throw "Too late to set session state"
    session_.session-state = state
    session_.state-bits_ |= Session.SESSION-PROVIDED_

  /**
  Returns one of $SESSION-MODE-CONNECTING, $SESSION-MODE-MBED-TLS, $SESSION-MODE-TOIT, $SESSION-MODE-CLOSED.
  */
  session-mode -> int:
    return session_.mode

  /**
  Returns true if the session was successfully resumed, rather
    than going through a full handshake with asymmetric crypto.
  Returns false until the handshake is complete.
  */
  session-resumed -> bool:
    return session_.resumed

  read -> ByteArray?:
    return session_.read

  write data from/int=0 to/int=data.size -> int:
    return session_.write data from to

  close -> none:
    session_.close
    socket_.close

  close-write -> none:
    session_.close-write
    socket_.close-write

  local-address -> net.SocketAddress:
    return socket_.local-address

  peer-address -> net.SocketAddress:
    return socket_.peer-address

  no-delay -> bool:
    return socket_.no-delay

  no-delay= value/bool:
    socket_.no-delay = value

  mtu -> int:
    return socket_.mtu - TLS-HEADER-SIZE_
