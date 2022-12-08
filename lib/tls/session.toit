// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import crypto.aes show *
import crypto.chacha20 show *
import monitor
import reader
import writer
import net.x509 as x509
import binary show BIG_ENDIAN

import .certificate
import .socket

// Record types from RFC 5246.
CHANGE_CIPHER_SPEC_ ::= 20
ALERT_ ::= 21
HANDSHAKE_ ::= 22
APPLICATION_DATA_ ::= 23

class KeyData_:
  key /ByteArray
  iv /ByteArray
  algorithm /int
  sequence_number_ /int := 0

  // Algorithm is one of ALGORITHM_AES_GCM or ALGORITHM_CHACHA20_POLY1305.
  constructor --.key --.iv --.algorithm/int:

  next_sequence_number -> ByteArray:
    result := ByteArray 8
    BIG_ENDIAN.put_int64 result 0 sequence_number_++
    return result

  has_explicit_iv -> bool:
    return algorithm == ALGORITHM_AES_GCM

  new_encryptor message_iv/ByteArray -> Aead_:
    if algorithm == ALGORITHM_AES_GCM:
      return AesGcm.encryptor key message_iv
    return ChaCha20Poly1305.encryptor key message_iv

  new_decryptor message_iv/ByteArray -> Aead_:
    if algorithm == ALGORITHM_AES_GCM:
      return AesGcm.decryptor key message_iv
    return ChaCha20Poly1305.decryptor key message_iv

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

  reader_/reader.BufferedReader? := ?
  writer_ ::= ?
  server_name_/string? ::= null

  // A latch until the handshake has completed.
  handshake_in_progress_/monitor.Latch? := monitor.Latch
  group_/TlsGroup_? := null
  tls_ := null

  outgoing_buffer_/ByteArray := #[]
  bytes_before_next_record_header_ := 0
  closed_for_write_ := false
  outgoing_sequence_numbers_used_ := 0
  incoming_sequence_numbers_used_ := 0

  reads_encrypted_ := false
  writes_encrypted_ := false
  symmetric_session_/SymmetricSession_? := null

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

    group_ = is_server ? tls_group_server_ : tls_group_client_
    handle := group_.use
    tls_ = tls_create_ handle server_name_
    add_finalizer this:: this.close

    root_certificates.do: tls_add_root_certificate_ tls_ it.res_
    if certificate:
      tls_add_certificate_ tls_ certificate.certificate.res_ certificate.private_key certificate.password
    tls_init_socket_ tls_ null
    if session_state:
      tls_set_session_ tls_ session_state

    resource_state := monitor.ResourceState_ handle tls_
    try:
      while true:
        tls_handshake_ tls_
        state := resource_state.wait
        resource_state.clear_state state
        with_timeout handshake_timeout:
          flush_outgoing_
        if state == TOIT_TLS_DONE_:
          extract_key_data_
          if symmetric_session_ != null:
            // We don't use MbedTLS any more.
            tls_close_ tls_
            tls_ = null
            group_.unuse
            group_ = null
          // Connected.
          return
        else if state == TOIT_TLS_WANT_READ_:
          with_timeout handshake_timeout:
            read_handshake_message_
        else if state == TOIT_TLS_WANT_WRITE_:
          // This is already handled above with flush_outgoing_
        else:
          tls_error_ handle state
    finally: | is_exception exception |
      value := is_exception ? exception.value : null
      handshake_in_progress_.set value
      handshake_in_progress_ = null
      resource_state.dispose

  extract_key_data_ -> none:
    if reads_encrypted_ and writes_encrypted_:
      key_data /List := tls_get_internals_ tls_
      if key_data != null:
        write_key_data := KeyData_ --key=key_data[1] --iv=key_data[3] --algorithm=key_data[0]
        read_key_data := KeyData_ --key=key_data[2] --iv=key_data[4] --algorithm=key_data[0]
        write_key_data.sequence_number_ = outgoing_sequence_numbers_used_
        read_key_data.sequence_number_ = incoming_sequence_numbers_used_
        symmetric_session_ = SymmetricSession_ writer_ reader_ write_key_data read_key_data

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
    if not tls_:
      if symmetric_session_: return symmetric_session_.write data from to
      throw "TLS_SOCKET_NOT_CONNECTED"
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
    if not tls_:
      if symmetric_session_: return symmetric_session_.read
      throw "TLS_SOCKET_NOT_CONNECTED"
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
    outgoing_buffer_ = #[]

  /**
  Closes the TLS session and releases any resources associated with it.
  */
  close:
    if tls_:
      critical_do:
        tls_close_ tls_
        tls_ = null
        group_.unuse
        group_ = null
        reader_.clear
        outgoing_buffer_ = #[]
        remove_finalizer this
    if reader_:
      // reader_.close TODO: Close the unbuffered_reader.
      reader_ = null
      writer_.close

  ensure_handshaken_:
    if not handshake_in_progress_: return
    handshake

  // This takes any data that the MbedTLS callback has deposited in the
  // outgoing_buffer_ byte array and writes it to the underlying socket.
  // During handshakes we also want to keep track of the record boundaries
  // so that we can switch to a Toit-level symmetric session when
  // handshaking is complete.  For this we need to know how many handshake
  // records were sent after encryption was activated.
  flush_outgoing_ -> none:
    from := 0
    pending_bytes := #[]
    while true:
      fullness := tls_get_outgoing_fullness_ tls_
      if fullness > from:
        while fullness - from > bytes_before_next_record_header_:
          // We have the start of the next record available.
          if fullness - from + 5 >= bytes_before_next_record_header_:
            // We have the full record header available.
            header := outgoing_buffer_[from + bytes_before_next_record_header_..]
            content_type := header[0]
            if content_type == CHANGE_CIPHER_SPEC_:
              writes_encrypted_ = true
            else if writes_encrypted_:
              outgoing_sequence_numbers_used_++
            record_size := BIG_ENDIAN.uint16 header 3
            // Set this so it skips the next header and its contents.
            bytes_before_next_record_header_ += 5 + record_size
          else:
            // We have a partial record header available.  Save up the partial
            // record for later.
            pending_bytes = outgoing_buffer_.copy (from + bytes_before_next_record_header_) (outgoing_buffer_.size)
            // Remove the partial record from the data we are about to send.
            fullness -= pending_bytes.size
        print "Sending:"
        List.chunk_up from fullness 8: | f t l |
          print "  $outgoing_buffer_[f..t]"
        sent := writer_.write outgoing_buffer_ from fullness
        from += sent
        bytes_before_next_record_header_ -= sent
      else:
        // The outgoing buffer can be neutered by the calls to
        // write. In that case, we allocate a fresh external one.
        if outgoing_buffer_.is_empty:
          outgoing_buffer_ = ByteArray_.external_ 1500
        // Be sure not to lose the pending bytes.  Instead put them in the
        // otherwise empty outgoing_buffer_.
        outgoing_buffer_.replace 0 pending_bytes
        tls_set_outgoing_ tls_ outgoing_buffer_ pending_bytes.size
        return

  read_more_ -> bool:
    from := tls_get_incoming_from_ tls_
    ba := reader_.read
    if not ba or not tls_: return false
    tls_set_incoming_ tls_ ba 0
    return true

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
    if (reader_.byte 0) == APPLICATION_DATA_:
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
      reads_encrypted_ = true
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
      if reads_encrypted_:
        incoming_sequence_numbers_used_++
        // Encrypted packet so we use the record header to determine size.
        remaining_message_bytes = BIG_ENDIAN.uint16 header 3
      else:
        // Unencrypted, so we use the message header to determine size, which
        // enables us to reassemble messages fragmented across multiple
        // records, something MbedTLS can't do alone.
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

class SymmetricSession_:
  write_keys /KeyData_
  read_keys /KeyData_
  writer_ ::= ?
  reader_ /reader.BufferedReader

  buffered_plaintext_index_ := 0
  buffered_plaintext_ := []

  constructor .writer_ .reader_ .write_keys .read_keys:

  write data from/int to/int -> int:
    if to - from  == 0: return 0
    // We want to be nice to the receiver in case it is an embedded device, so we
    // don't send too large records.  This size is intended to fit in two MTUs on
    // Ethernet.
    List.chunk_up from to 2800: | from2/int to2/int length2 |
      record_header := #[APPLICATION_DATA_, 3, 3, 0, 0]
      BIG_ENDIAN.put_uint16 record_header 3 length2
      // AES-GCM:
      // The explicit (transmitted) part of the IV (nonce) must not be reused,
      // but apart from that there are no requirements.  We just reuse the
      // sequence number, which is a common solution.
      // ChaCha20-Poly1305:
      // There is no explict (transmitted) part of the IV, so it is a
      // requirement that we use the sequence number to keep the local and
      // remote IVs in sync.  As described in RFC8446 section 5.3 the serial
      // number is xored with the last 8 bytes of the 12 byte nonce.
      iv := write_keys.iv.copy
      sequence_number /ByteArray := write_keys.next_sequence_number
      explicit_iv /ByteArray := ?
      if write_keys.has_explicit_iv:
        explicit_iv = sequence_number
        iv.replace 4 explicit_iv
      else:
        explicit_iv = #[]
        8.repeat: iv[4 + it] ^= sequence_number[it]
      encryptor := write_keys.new_encryptor iv
      encryptor.start --authenticated_data=(sequence_number + record_header)
      // Now that we have used the actual size of the plaintext as the authentication data
      // we update the header with the real size on the wire, which includes some more data.
      real_length := length2 + explicit_iv.size + Aead_.TAG_SIZE
      print "length=$length2 real_length=$real_length"
      BIG_ENDIAN.put_uint16 record_header 3 real_length
      List.chunk_up from2 to2 512: | from3 to3 length3 |
        first /bool := from3 == from2
        last /bool := to3 == to2
        plaintext := data is string
            ? data.to_byte_array from3 to3
            : data.copy from3 to3
        parts := [encryptor.add plaintext]
        if first:
          parts = [record_header, explicit_iv, parts[0]]
        if last:
          parts.add encryptor.finish
        else:
          yield  // Don't monopolize the CPU with long crypto operations.
        encrypted := byte_array_join_ parts
        print "Encrypted $encrypted.size bytes: $encrypted"
        written := 0
        while written < encrypted.size:
          written += writer_.write encrypted written
    return to - from

  read -> ByteArray?:
    result := null
    try:
      result = read_
      return result
    finally: | is_exception exception |
      if not result or is_exception:
        // If anything goes wrong we close the connection - don't want to give
        // anyone a second chance to probe us with dodgy data.
        //reader_.close
        writer_.close

  read_ -> ByteArray?:
    while true:
      if buffered_plaintext_index_ != buffered_plaintext_.size:
        return buffered_plaintext_[buffered_plaintext_index_++]
      record_header := reader_.read_bytes 5
      if not record_header: return null
      if record_header[0] == ALERT_:
        throw "Alert, size $(BIG_ENDIAN.uint16 record_header 3)"
      if record_header[0] != APPLICATION_DATA_ or record_header[1] != 3 or record_header[2] != 3: throw "PROTOCOL_ERROR $record_header"
      encrypted_length := BIG_ENDIAN.uint16 record_header 3
      // According to RFC5246: The length MUST NOT exceed 2^14 + 1024.
      if encrypted_length > (1 << 14) + 1024: throw "PROTOCOL_ERROR"

      explicit_iv /ByteArray := ?
      iv /ByteArray := read_keys.iv.copy
      sequence_number := read_keys.next_sequence_number
      if read_keys.has_explicit_iv:
        explicit_iv = reader_.read_bytes 8
        if not explicit_iv: return null
        iv.replace 4 explicit_iv
      else:
        explicit_iv = #[]
        8.repeat: iv[4 + it] ^= sequence_number[it]

      plaintext_length := encrypted_length - Aead_.TAG_SIZE - explicit_iv.size
      decryptor := read_keys.new_decryptor iv
      // Overwrite the length with the unpadded length before adding the header
      // to the authenticated data.
      BIG_ENDIAN.put_uint16 record_header 3 plaintext_length
      decryptor.start --authenticated_data=(sequence_number + record_header)
      // Accumulate plaintext in a local to ensure that no data is read by the
      // application that has not been verified.
      buffered_plaintext := []
      while plaintext_length > 0:
        encrypted := reader_.read --max_size=plaintext_length
        if not encrypted: return null
        plaintext_length -= encrypted.size
        plain_chunk := decryptor.add encrypted
        if plain_chunk.size != 0: buffered_plaintext.add plain_chunk
      received_tag := reader_.read_bytes Aead_.TAG_SIZE
      if not received_tag: return null
      plain_chunk := decryptor.verify received_tag
      // Since we got here, the tag was successfully verified.
      if plain_chunk.size != 0: buffered_plaintext.add plain_chunk
      buffered_plaintext_ = buffered_plaintext
      buffered_plaintext_index_ = 0

TOIT_TLS_DONE_ := 1 << 0
TOIT_TLS_WANT_READ_ := 1 << 1
TOIT_TLS_WANT_WRITE_ := 1 << 2

tls_group_client_ ::= TlsGroup_ false
tls_group_server_ ::= TlsGroup_ true

class TlsGroup_:
  handle_/ByteArray? := null
  is_server_/bool
  users_/int := 0
  constructor .is_server_:

  use -> ByteArray:
    users_++
    if handle_: return handle_
    return handle_ = tls_init_ is_server_

  unuse -> none:
    users_--
    if users_ == 0:
      handle := handle_
      handle_ = null
      tls_deinit_ handle

byte_array_join_ arrays/List -> ByteArray:
  if arrays.size == 0: return #[]
  if arrays.size == 1: return arrays[0]
  if arrays.size == 2: return arrays[0] + arrays[1]
  size := arrays.reduce --initial=0: | a b | a + b.size
  result := ByteArray size
  position := 0
  arrays.do:
    result.replace position it
    position += it.size
  return result

tls_init_ is_server/bool:
  #primitive.tls.init

tls_deinit_ group:
  #primitive.tls.deinit

tls_create_ group hostname:
  #primitive.tls.create

tls_add_root_certificate_ group cert:
  #primitive.tls.add_root_certificate

tls_error_ group error:
  #primitive.tls.error

tls_init_socket_ tls_socket transport_id:
  #primitive.tls.init_socket

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

tls_add_certificate_ tls_socket public_byte_array private_byte_array password:
  #primitive.tls.add_certificate

tls_set_incoming_ tls_socket byte_array from:
  #primitive.tls.set_incoming

tls_get_incoming_from_ tls_socket:
  #primitive.tls.get_incoming_from

tls_set_outgoing_ tls_socket byte_array fullness:
  #primitive.tls.set_outgoing

tls_get_outgoing_fullness_ tls_socket:
  #primitive.tls.get_outgoing_fullness

tls_get_session_ tls_socket -> ByteArray:
  #primitive.tls.get_session

tls_set_session_ tls_socket session/ByteArray:
  #primitive.tls.set_session

tls_get_internals_ tls_socket -> List:
  #primitive.tls.get_internals
