// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor
import reader
import writer
import net.x509 as x509

import .certificate
import .socket

/**
TLS Session upgrades a reader/writer pair to a TLS encrypted communication channel.

The most common usage of a TLS session is for upgrading a TCP socket to secure TLS socket.
  For that use-case see $Socket.
*/
class Session:
  static DEFAULT_HANDSHAKE_TIMEOUT ::= Duration --s=10
  is_server/bool ::= false
  certificate/Certificate?
  root_certificates/List
  handshake_timeout/Duration

  reader_/reader.Reader
  writer_ ::= ?
  server_name_/string? ::= null

  // A latch until the handshake has completed.
  handshake_in_progress_/monitor.Latch? := monitor.Latch
  tls_ := null
  outgoing_byte_array_ := ByteArray 1500
  incoming_to_ := 0
  closed_for_write_ := false

  /**
  Creates a new TLS session at the client-side.

  If $server_name is provided, it will validate the peer certificate against that. If
    the $server_name is omitted, it will skip verification.
  The $root_certificates are used to validate the peer certificate.
  If $certificate is given, the certificate is used by the server to validate the
    authority of the client. This is not done using e.g. HTTPS communication.
  The handshake routine requires at most $handshake_timeout between each step
    in the handshake process.
  */
  constructor.client .reader_ .writer_
      --server_name/string?=null
      --.certificate=null
      --.root_certificates=[]
      --.handshake_timeout/Duration=DEFAULT_HANDSHAKE_TIMEOUT:
    server_name_ = server_name

  /**
  Creates a new TLS session at the server-side.

  The $root_certificates are used to validate the peer certificate.
  If $certificate is given, the certificate is used by the server to validate the
    authority of the client. This is not done using e.g. HTTPS communication.
  The handshake routine requires at most $handshake_timeout between each step
    in the handshake process.
  */
  constructor.server .reader_ .writer_
      --.certificate=null
      --.root_certificates=[]
      --.handshake_timeout/Duration=DEFAULT_HANDSHAKE_TIMEOUT:
    is_server = true

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
    if tls_:
      if not handshake_in_progress_: throw "TLS_ALREADY_HANDSHAKEN"
      error := handshake_in_progress_.get
      if error: throw error
      return

    group := is_server ? tls_group_server_ : tls_group_client_
    tls_ = tls_create_ group server_name_
    root_certificates.do: tls_add_root_certificate_ tls_ it.res_
    if certificate:
      tls_add_certificate_ tls_ certificate.certificate.res_ certificate.private_key certificate.password
    tls_init_socket_ tls_ null
    if session_state:
      tls_set_session_ tls_ session_state
    tls_set_outgoing_ tls_ outgoing_byte_array_ 0

    resource_state := monitor.ResourceState_ group tls_
    try:
      while true:
        tls_handshake_ tls_
        state := resource_state.wait
        resource_state.clear_state state
        with_timeout handshake_timeout:
          flush_outgoing_
        if state == TOIT_TLS_DONE_:
          // Connected.
          return
        else if state == TOIT_TLS_WANT_READ_:
          with_timeout handshake_timeout:
            if not read_more_: throw "TLS_CONNECTION_CLOSED_DURING_HANDSHAKE"
        else if state == TOIT_TLS_WANT_WRITE_:
          // This is already handled above with flush_outgoing_
        else:
          tls_error_ group state
    finally: | is_exception exception |
      value := is_exception ? exception.value : null
      handshake_in_progress_.set value
      handshake_in_progress_ = null

  /**
  Gets the session state, a ByteArray that can be used to resume
    a TLS session at a later point.

  The session can be read at any point after a handshake, but before the session
    is closed.
  */
  session_state -> ByteArray:
    return tls_get_session_ tls_

  write data from=0 to=data.size:
    ensure_handshaken_
    if not tls_: throw "TLS_SOCKET_NOT_CONNECTED"
    sent := 0
    while true:
      if from == to:
        flush_outgoing_
        return sent
      wrote := tls_write_ tls_ data from to
      if wrote == 0: flush_outgoing_
      if wrote < 0: throw "UNEXPECTED_TLS_STATUS: $wrote"
      from += wrote
      sent += wrote

  read:
    ensure_handshaken_
    if not tls_: throw "TLS_SOCKET_NOT_CONNECTED"
    while true:
      res := tls_read_ tls_
      if res == TOIT_TLS_WANT_READ_:
        if not read_more_: return null
      else:
        return res

  /**
  Closes the session for write operations.

  Consider using $close instead of this method.
  */
  close_write:
    if not tls_: return
    if closed_for_write_: return
    tls_close_write_ tls_
    flush_outgoing_
    closed_for_write_ = true

  /**
  Closes the TLS session and releases any resources associated with it.
  */
  close:
    if tls_:
      tls_close_ tls_
      tls_ = null

  ensure_handshaken_:
    if not handshake_in_progress_: return
    handshake

  flush_outgoing_ -> none:
    from := 0
    while true:
      fullness := tls_get_outgoing_fullness_ tls_
      if fullness > from:
        sent := writer_.write outgoing_byte_array_ from fullness
        from += sent
      else:
        tls_set_outgoing_ tls_ outgoing_byte_array_ 0
        return

  read_more_:
    while true:
      from := tls_get_incoming_from_ tls_
      if incoming_to_ > from: return true
      ba := reader_.read
      if not ba: return false
      tls_set_incoming_ tls_ ba 0
      if ba.size > 0: return true

TOIT_TLS_DONE_ := 1 << 0
TOIT_TLS_WANT_READ_ := 1 << 1
TOIT_TLS_WANT_WRITE_ := 1 << 2

tls_group_client_ ::= tls_init_ false
tls_group_server_ ::= tls_init_ true

tls_init_ server:
  #primitive.tls.init

tls_init_socket_ group transport_id:
  #primitive.tls.init_socket

tls_create_ module hostname:
  #primitive.tls.create

tls_handshake_ tls_socket:
  #primitive.tls.handshake

tls_read_ tls_socket:
  #primitive.tls.read

tls_write_ tls_socket bytes from to:
  #primitive.tls.write

tls_close_write_ tls_socket:
  #primitive.tls.close_write

tls_close_ tls_socket:
  #primitive.tls.close

tls_add_root_certificate_ module cert:
  #primitive.tls.add_root_certificate

tls_add_certificate_ socket public_byte_array private_byte_array password:
  #primitive.tls.add_certificate

tls_set_incoming_ socket byte_array from:
  #primitive.tls.set_incoming

tls_get_incoming_from_ socket:
  #primitive.tls.get_incoming_from

tls_set_outgoing_ socket byte_array fullness:
  #primitive.tls.set_outgoing

tls_get_outgoing_fullness_ socket:
  #primitive.tls.get_outgoing_fullness

tls_error_ group error:
  #primitive.tls.error

tls_get_session_ tls_socket -> ByteArray:
  #primitive.tls.get_session

tls_set_session_ tls_socket session/ByteArray:
  #primitive.tls.set_session
