// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import net
import net.tcp

import .session
import .certificate

/**
TLS socket implementation that can upgrade a TCP socket to a secure TLS socket.
*/
class Socket extends Object with io.CloseableInMixin io.CloseableOutMixin implements tcp.Socket:
  static TLS-HEADER-SIZE_ ::= 29

  socket_/tcp.Socket
  session_/Session

  /**
  Creates a new TLS socket for a client-side TCP socket.

  If $server-name is provided, it will validate the peer certificate against that. If
    the $server-name is omitted, it will skip validation.

  The $root-certificates are used to validate the peer certificate. It is
    generally preferred to install root certificates on a process level,
    rather than passing them to each TLS socket.

  If $certificate is given, the certificate is used by the server to validate the
    authority of the client. This is not done using e.g. HTTPS communication.
  The handshake routine requires at most $handshake-timeout between each step
    in the handshake process.

  Validation of the server certificate can be disabled by setting
    $skip-certificate-validation to true. This is not recommended, as it
    allows man-in-the-middle attacks. However, establishing a connection
    without verification consumes less resources, and can be useful in some
    cases.
  When connecting to a server that uses a self-signed certificate prefer to
    install the server's certificate as root certificate.
  */
  constructor.client .socket_/tcp.Socket
      --server-name/string?=null
      --certificate/Certificate?=null
      --root-certificates=[]
      --handshake-timeout/Duration=Session.DEFAULT-HANDSHAKE-TIMEOUT
      --skip-certificate-validation/bool=false:
    session_ = Session.client socket_.in socket_.out
      --server-name=server-name
      --certificate=certificate
      --root-certificates=root-certificates
      --handshake-timeout=handshake-timeout
      --skip-certificate-validation=skip-certificate-validation

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
    session_ = Session.server socket_.in socket_.out
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

  /** Deprecated. Use $(in).read. */
  read -> ByteArray?:
    return read_

  read_ -> ByteArray?:
    return session_.read

  /** Deprecated. Use $(out).write. */
  write data/io.Data from/int=0 to/int=data.byte-size -> int:
    return try-write_ data from to

  try-write_ data/io.Data from/int to/int -> int:
    return session_.write data from to

  close -> none:
    session_.close
    socket_.close

  /** Deprecated. Use $(out).close. */
  close-write -> none:
    close-writer_

  close-writer_ -> none:
    session_.close-write
    socket_.out.close

  close-reader_ -> none:
    // TODO(florian): Implement.

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
