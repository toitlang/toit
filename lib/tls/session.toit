// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor
import reader
import writer
import net.x509 as x509
import binary show BIG_ENDIAN

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

  reader_/reader.BufferedReader
  switched_to_encrypted_ := false
  writer_ ::= ?
  server_name_/string? ::= null

  // A latch until the handshake has completed.
  handshake_in_progress_/monitor.Latch? := monitor.Latch
  tls_ := null
  outgoing_byte_array_ := ByteArray 1500
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
  constructor.client unbuffered_reader .writer_
      --server_name/string?=null
      --.certificate=null
      --.root_certificates=[]
      --.handshake_timeout/Duration=DEFAULT_HANDSHAKE_TIMEOUT:
    reader_ = reader.BufferedReader unbuffered_reader
    server_name_ = server_name

  /**
  Creates a new TLS session at the server-side.

  The $root_certificates are used to validate the peer certificate.
  If $certificate is given, the certificate is used by the server to validate the
    authority of the client. This is not done using e.g. HTTPS communication.
  The handshake routine requires at most $handshake_timeout between each step
    in the handshake process.
  */
  constructor.server unbuffered_reader .writer_
      --.certificate=null
      --.root_certificates=[]
      --.handshake_timeout/Duration=DEFAULT_HANDSHAKE_TIMEOUT:
    reader_ = reader.BufferedReader unbuffered_reader
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
    add_finalizer this:: this.close
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
            read_handshake_message_
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
      remove_finalizer this

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

  read_more_ -> bool:
    from := tls_get_incoming_from_ tls_
    ba := reader_.read
    if not ba: return false
    tls_set_incoming_ tls_ ba 0
    return true

  // Record types from RFC 5246.
  static CHANGE_CIPHER_SPEC_ ::= 20
  static ALERT_ ::= 21
  static HANDSHAKE_ ::= 22
  static APPLICATION_DATA_ ::= 23

  is_ascii_ c/int -> bool:
    if ' ' <= c <= '~': return true
    if c == '\n': return true
    if c == '\t': return true
    return c == '\r'

  // The TLS protocol has two layers.  The record layer breaks up the data into
  // records with 5 byte record headers.  In the payload of the records we find
  // the message layer.  The message layer contains a stream of messages, of
  // which there are four types.  A given record can only contain messages of
  // one type, but a message can be fragmented over multiple records and a record
  // can contain multiple messages.
  //
  // MbedTLS can't reassemble handshake messages that span more than one
  // TLS record.  Once handshaking is done it does not have a problem with
  // reassembling the messages, which are all of the APPLICATION_DATA_ type.
  //
  // During handshake we may therefore need to create synthetic records
  // that contain only complete messages.
  //
  // If a message doesn't end on a record boundary, the buffered reader has
  // some amount of data that belongs to the next fictional record.  We unget 5
  // bytes of data to create an synthetic record boundary.
  //
  // At some point MbedTLS gets a CHANGE_CIPHER_SPEC_ message, and after
  // this point the data from the other side is encrypted.  This happens
  // fairly late in the handshaking, and we have to hope that no more
  // fragmented messages arrive after this point, because we can no longer
  // understand the message data and defragment it.

  // Reads and blocks until we have enough data to construct a whole
  // handshaking message.  May return an synthetic record, (defragmented
  // from several records on the wire).
  extract_first_message_ -> ByteArray:
    if switched_to_encrypted_ or (reader_.byte 0) == APPLICATION_DATA_:
      // We rarely (never?) find a record with the application data type
      // because normally we have switched to encrypted mode before this
      // happens.  In any case we lose the ability to see the message
      // structure when encryption is activated and from this point we
      // just feed data unchanged to MbedTLS.
      return reader_.read
    header := reader_.read_bytes 5
    content_type := header[0]
    remaining_message_bytes / int := ?
    if content_type == ALERT_:
      remaining_message_bytes = 2
    else if content_type == CHANGE_CIPHER_SPEC_:
      remaining_message_bytes = 1
      switched_to_encrypted_ = true
    else:
      if content_type != HANDSHAKE_:
        // If we get an unknown record type the probable reason is that
        // we are not connecting to a real TLS server.  Often we have
        // accidentally connected to an HTTP server instead.  If the
        // response looks like ASCII then put it in the error thrown -
        // it may be helpful.
        reader_.unget header
        text_end := 0
        while text_end < 100 and text_end < reader_.buffered and is_ascii_ (reader_.byte text_end):
          text_end++
        server_reply := ""
        if text_end > 2:
          server_reply = "- server replied unencrypted:\n$(reader_.read_string text_end)"
        throw "Unknown TLS record type: $content_type$server_reply"
      reader_.ensure 4  // 4 byte handshake message header.
      // Big endian 24 bit handshake message size.
      remaining_message_bytes = (reader_.byte 1) << 16
      remaining_message_bytes += (reader_.byte 2) << 8
      remaining_message_bytes += (reader_.byte 3)
      remaining_message_bytes += 4  // Encoded size does not include the 4 byte handshake header.

    // The protocol requires that records are less than 16k large, so if there is
    // a single message that doesn't fit in a record we can't defragment.  MbedTLS
    // has a lower limit, currently configured to 6000 bytes, so this isn't actually
    // limiting us.
    if remaining_message_bytes >= 0x4000: throw "TLS handshake message too large to defragment"
    // Make an artificial record that was not on the wire.
    record := ByteArray remaining_message_bytes + 5  // Include space for header.
    record.replace 0 header
    // Overwrite record size of header.
    BIG_ENDIAN.put_uint16 record 3 remaining_message_bytes
    remaining_in_record := BIG_ENDIAN.uint16 header 3
    while remaining_message_bytes > 0:
      m := min remaining_in_record remaining_message_bytes
      chunk := reader_.read --max_size=m
      record.replace (record.size - remaining_message_bytes) chunk
      remaining_message_bytes -= chunk.size
      remaining_in_record -= chunk.size
      if remaining_in_record == 0 and remaining_message_bytes != 0:
        header = reader_.read_bytes 5  // Next record header.
        if header[0] != content_type: throw "Unexpected content type in continued record"
        remaining_in_record = BIG_ENDIAN.uint16 header 3
    if remaining_in_record != 0:
      // The message ended in the middle of a record.  We have to unget an
      // artificial record header to the stream to take care of the rest of
      // the record.
      reader_.ensure 1
      synthetic_header := header.copy
      BIG_ENDIAN.put_uint16 synthetic_header 3 remaining_in_record
      reader_.unget synthetic_header
    return record

  read_handshake_message_ -> none:
    packet := extract_first_message_
    tls_set_incoming_ tls_ packet 0


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
