// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show BIG_ENDIAN
import crypto.aes show *
import crypto.chacha20 show *
import crypto.checksum
import crypto.hmac show Hmac
import crypto.sha show Sha256 Sha384
import encoding.tison
import monitor
import net.x509 as x509
import reader
import writer

import .certificate
import .socket

// Record types from RFC 5246 section 6.2.1.
CHANGE_CIPHER_SPEC_ ::= 20
ALERT_              ::= 21
HANDSHAKE_          ::= 22
APPLICATION_DATA_   ::= 23

// Handshake message types from RFC 5246 section 7.4.
HELLO_REQUEST_       ::= 0
CLIENT_HELLO_        ::= 1
SERVER_HELLO_        ::= 2
NEW_SESSION_TICKET_  ::= 4
CERTIFICATE_         ::= 11
SERVER_KEY_EXCHANGE_ ::= 12
CERTIFICATE_REQUEST_ ::= 13
SERVER_HELLO_DONE_   ::= 14
CERTIFICATE_VERIFY_  ::= 15
CLIENT_KEY_EXCHANGE_ ::= 16
FINISHED_            ::= 20

ALERT_WARNING_ ::= 1
ALERT_FATAL_   ::= 2

RECORD_HEADER_SIZE_ ::= 5
CLIENT_RANDOM_SIZE_ ::= 32

EXTENSION_SERVER_NAME_            ::= 0
EXTENSION_EXTENDED_MASTER_SECRET_ ::= 23
EXTENSION_SESSION_TICKET_         ::= 35

class RecordHeader_:
  bytes /ByteArray      // At least 5 bytes.
  type -> int: return bytes[0]
  major_version -> int: return bytes[1]
  minor_version -> int: return bytes[2]
  length -> int: return BIG_ENDIAN.uint16 bytes 3
  length= value/int: BIG_ENDIAN.put_uint16 bytes 3 value

  constructor .bytes:

class HandshakeHeader_:
  bytes /ByteArray     // At least 9 bytes.  Includes the record header.
  type -> int: return bytes[5]
  length -> int: return BIG_ENDIAN.uint24 bytes 6
  length= value/int: BIG_ENDIAN.put_uint24 bytes 6 value

  constructor .bytes:

class KeyData_:
  key /ByteArray
  iv /ByteArray
  algorithm /int
  sequence_number_ /int := 0

  // Algorithm is one of ALGORITHM_AES_GCM or ALGORITHM_CHACHA20_POLY1305.
  constructor --.key --.iv --.algorithm/int:
    // Both algorithms require a 12 byte IV, so we pad.
    iv += ByteArray (12 - iv.size)

  next_sequence_number -> ByteArray:
    result := ByteArray 8
    BIG_ENDIAN.put_int64 result 0 sequence_number_++
    // We can't allow the sequence number to wrap around, because that would lead
    // to iv reuse.  In the unlikely event that we transmit so much data we
    // have to throw an exception and close the connection.
    if sequence_number_ < 0: throw "CONNECTION_EXHAUSTED"
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

// TLS verifying certificates and performing asymmetric crypto.
SESSION_MODE_CONNECTING ::= 0
// TLS connected, using symmetric crypto, controlled by MbedTLS.
SESSION_MODE_MBED_TLS   ::= 1
// TLS connected, using symmetric crypto, controlled in Toit.
SESSION_MODE_TOIT       ::= 2
// TLS connection closed.
SESSION_MODE_CLOSED     ::= 3

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
  unbuffered_reader_ := ?
  writer_ ::= ?
  server_name_/string? ::= null

  handshake_in_progress_/monitor.Latch? := null
  tls_ := null
  tls_group_/TlsGroup_? := null

  outgoing_buffer_/ByteArray := #[]
  bytes_before_next_record_header_ := 0
  closed_for_write_ := false
  outgoing_sequence_numbers_used_ := 0
  incoming_sequence_numbers_used_ := 0

  reads_encrypted_ := false
  writes_encrypted_ := false
  symmetric_session_/SymmetricSession_? := null

  /**
  Returns one of the SESSION_MODE_* constants.
  */
  mode -> int:
    if tls_:
      if reads_encrypted_ and writes_encrypted_:
        return SESSION_MODE_MBED_TLS
      else:
        return SESSION_MODE_CONNECTING
    else:
      if symmetric_session_:
        return SESSION_MODE_TOIT
      else:
        return SESSION_MODE_CLOSED

  /**
  Creates a new TLS session at the client-side.

  If $server_name is provided, it will validate the peer certificate against
    that. If the $server_name is omitted, it will skip verification.
  The $root_certificates are used to validate the peer certificate.
  If $certificate is given, the certificate is used by the server to validate
    the authority of the client. This is not usually done on the web, where
    normally only the client verifies the server
  The handshake routine requires at most $handshake_timeout between each step
    in the handshake process.
  If $session_state is given, the handshake operation will use it to resume the
    TLS session from the previous stored session state. This can greatly
    improve the duration of a complete TLS handshake. If the session state is
    given, but rejected by the server, an error will be thrown, and the
    operation must be retried without stored session data.
  */
  constructor.client .unbuffered_reader_ .writer_
      --server_name/string?=null
      --.certificate=null
      --.root_certificates=[]
      --.session_state=null
      --.handshake_timeout/Duration=DEFAULT_HANDSHAKE_TIMEOUT:
    reader_ = reader.BufferedReader unbuffered_reader_
    server_name_ = server_name

  /**
  Creates a new TLS session at the server-side.

  The $root_certificates are used to validate the peer certificate.
  If $certificate is given, the certificate is used by the server to validate
    the authority of the client. This is not usually done on the web,
    where normally only the client verifies the server.
  The handshake routine requires at most $handshake_timeout between each step
    in the handshake process.
  */
  constructor.server .unbuffered_reader_ .writer_
      --.certificate=null
      --.root_certificates=[]
      --.handshake_timeout/Duration=DEFAULT_HANDSHAKE_TIMEOUT:
    reader_ = reader.BufferedReader unbuffered_reader_
    is_server = true

  /**
  Explicitly completes the handshake step.

  This method will automatically be called by read and write if the handshake
    is not completed yet.
  */
  handshake -> none:
    if not reader_:
      throw "ALREADY_CLOSED"
    else if handshake_in_progress_:
      handshake_in_progress_.get  // Throws if an exception was set.
      return
    else if symmetric_session_ or tls_group_:
      throw "TLS_ALREADY_HANDSHAKEN"

    handshake_in_progress_ = monitor.Latch

    if session_state:
      try:
        result := (ToitHandshake_ this).handshake
        set_up_symmetric_session_ result
        // Connected.
        return
      finally: | is_exception exception |
        value := is_exception ? exception.value : null
        handshake_in_progress_.set value --exception=is_exception
        handshake_in_progress_ = null

    tls_group := is_server ? tls_group_server_ : tls_group_client_

    token := null
    token_state/monitor.ResourceState_? := null
    tls := null
    tls_state/monitor.ResourceState_? := null
    try:
      group := tls_group.use

      // We allow the VM to prevent too many concurrent
      // handshakes because they are very memory intensive.
      // We acquire a token and we must wait until the
      // token has a non-zero state before we are allowed
      // to start the handshake process. When releasing
      // the token, we notify the first waiter if any.
      token = tls_token_acquire_ group
      token_state = ResourceState_ group token
      token_state.wait
      token_state.dispose
      token_state = null

      tls = tls_create_ group server_name_
      tls_state = monitor.ResourceState_ group tls
      // TODO(kasper): It would be great to be able to set
      // the field after the successful handshake, but a
      // good chunk of methods use the field indirectly as
      // part of completing the handshake.
      tls_ = tls
      handshake_ tls_state --session_state=session_state

    finally: | is_exception exception |
      if token_state: token_state.dispose
      if tls_state: tls_state.dispose
      if is_exception: reader_ = null

      if is_exception or symmetric_session_ != null:
        // We do not need the resources any more. Either
        // because we're running in Toit mode using a
        // symmetric session or because we failed to do
        // the handshake.
        if tls: tls_close_ tls
        tls_group.unuse
        tls_ = null
      else:
        // Delay the closing of the TLS group and resource
        // until $close is called.
        tls_group_ = tls_group
        add_finalizer this:: close

      // Release the handshake token if we managed to
      // create the resource group.
      if token: tls_token_release_ token

      // Mark the handshake as no longer in progress and
      // send back any exception to whoever may be waiting
      // for the handshake to complete.
      handshake_in_progress_.set (is_exception ? exception : null)
          --exception=is_exception
      handshake_in_progress_ = null

  handshake_ tls_state/monitor.ResourceState_ --session_state/ByteArray?=null -> none:
    root_certificates.do: tls_add_root_certificate_ tls_ it.res_
    if certificate:
      tls_add_certificate_ tls_ certificate.certificate.res_ certificate.private_key certificate.password
    tls_init_socket_ tls_ null

    while true:
      tls_handshake_ tls_
      state := tls_state.wait
      tls_state.clear_state state
      with_timeout handshake_timeout:
        flush_outgoing_
      if state == TOIT_TLS_DONE_:
        extract_key_data_
        return  // Connected.
      else if state == TOIT_TLS_WANT_READ_:
        with_timeout handshake_timeout:
          read_handshake_message_
      else if state == TOIT_TLS_WANT_WRITE_:
        // This is already handled above with flush_outgoing_
      else:
        tls_error_ tls_state.group state

  extract_key_data_ -> none:
    if reads_encrypted_ and writes_encrypted_:
      key_data /List? := tls_get_internals_ tls_
      session_state = tison.encode key_data[5..9]
      if key_data != null:
        write_key_data := KeyData_ --key=key_data[1] --iv=key_data[3] --algorithm=key_data[0]
        read_key_data := KeyData_ --key=key_data[2] --iv=key_data[4] --algorithm=key_data[0]
        write_key_data.sequence_number_ = outgoing_sequence_numbers_used_
        read_key_data.sequence_number_ = incoming_sequence_numbers_used_
        symmetric_session_ = SymmetricSession_ this writer_ reader_ write_key_data read_key_data

  /**
  Gets the session state, a ByteArray that can be used to resume
    a TLS session at a later point.

  The session can be read at any point after a handshake.

  The session state is a Tison-encoded list of 3 byte arrays and an integer:
  The first byte array is the session ID, the second is the session ticket, and
    the third is the master secret.  The session ID and session ticket are
    mutually exclusive (only one of them has a non-zero length).  The fourth
    item is an integer giving the ciphersuite used.
  */
  session_state/ByteArray? := null

  /**
  Called after a pure-Toit handshake has completed.  This sets up the
    symmetric session and checks that the handshake checksums match.
  We have to switch to encrypted mode to receive and send the last
    two handshake messages.  We do this before knowing if the handshake
    succeeded.
  */
  set_up_symmetric_session_ handshake_result/List -> none:
    reads_encrypted_ = true
    writes_encrypted_ = true
    symmetric_session_ = handshake_result[0]
    client_finished /ByteArray := handshake_result[1]
    server_finished_expected /ByteArray := handshake_result[2]
    session_id /ByteArray := handshake_result[3]
    session_ticket /ByteArray := handshake_result[4]
    master_secret /ByteArray := handshake_result[5]
    cipher_suite_id /int := handshake_result[6]

    // Get the server finished message.  This assumes we are the client.
    server_finished := symmetric_session_.read --expected_type=HANDSHAKE_
    if not compare_byte_arrays_ server_finished_expected server_finished:
      throw "TLS_HANDSHAKE_FAILED"
    // Send the client finished message.  This assumes we are the client.
    symmetric_session_.write client_finished 0 client_finished.size --type=HANDSHAKE_

    // Update the session data for any third connection.
    session_state = tison.encode [
        session_id,
        session_ticket,
        master_secret,
        cipher_suite_id,
    ]

  write data from=0 to=data.size:
    ensure_handshaken_
    if symmetric_session_: return symmetric_session_.write data from to
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
    if symmetric_session_: return symmetric_session_.read
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
    outgoing_buffer_ = #[]

  /**
  Closes the TLS session and releases any resources associated with it.
  */
  close -> none:
    if tls_:
      tls_close_ tls_
      tls_ = null
      tls_group_.unuse
      tls_group_ = null
      reader_.clear
      outgoing_buffer_ = #[]
      remove_finalizer this
    if reader_:
      reader_ = null
      writer_.close
    if unbuffered_reader_:
      unbuffered_reader_.close
      unbuffered_reader_ = null
    symmetric_session_ = null

  ensure_handshaken_:
    // TODO(kasper): It is a bit unfortunate that the $tls_ field
    // is set while we're doing the handshaking. Because of that
    // we have to check that $handshake_in_progress_ is null
    // before we can conclude that we're already handshaken.
    if symmetric_session_ or (tls_ and not handshake_in_progress_): return
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
          if fullness - from + RECORD_HEADER_SIZE_ >= bytes_before_next_record_header_:
            // We have the full record header available.
            header := RecordHeader_ outgoing_buffer_[from + bytes_before_next_record_header_..]
            record_size := header.length
            if header.type == CHANGE_CIPHER_SPEC_:
              writes_encrypted_ = true
            else if writes_encrypted_:
              outgoing_sequence_numbers_used_++
              check_for_zero_explicit_iv_ header
            // Set this so it skips the next header and its contents.
            bytes_before_next_record_header_ += RECORD_HEADER_SIZE_ + record_size
          else:
            // We have a partial record header available.  Save up the partial
            // record for later.
            pending_bytes = outgoing_buffer_.copy (from + bytes_before_next_record_header_) (outgoing_buffer_.size)
            // Remove the partial record from the data we are about to send.
            fullness -= pending_bytes.size
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

  check_for_zero_explicit_iv_ header/RecordHeader_ -> none:
    if header.length == 0x28 and header.bytes.size >= 13:
      // If it looks like the checksum of the handshake, encoded with
      // AES-GCM, then we check that the explicit nonce is 0.  This
      // is always the case with the current MbedTLS, but since we
      // can't reuse nonces without destroying security we would like
      // a heads-up if a new version of MbedTLS changes this default.
      if header.bytes[RECORD_HEADER_SIZE_..RECORD_HEADER_SIZE_ + 8] != #[0, 0, 0, 0, 0, 0, 0, 0]: throw "MBEDTLS_TOIT_INCOMPATIBLE"

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
  // this point the data from the other side is encrypted.

  // Reads and blocks until we have enough data to construct a whole
  // handshaking message.  May return a synthetic record, (defragmented
  // from several records on the wire).
  extract_first_message_ -> ByteArray:
    if (reader_.byte 0) == APPLICATION_DATA_:
      // We rarely (never?) find a record with the application data type
      // because normally we have switched to encrypted mode before this
      // happens.  In any case we lose the ability to see the message
      // structure when encryption is activated and from this point we
      // just feed data unchanged to MbedTLS.
      return reader_.read
    header := RecordHeader_ (reader_.read_bytes RECORD_HEADER_SIZE_)
    content_type := header.type
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
        reader_.unget header.bytes
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
        remaining_message_bytes = header.length
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
    // Make a synthetic record that was not on the wire.
    synthetic := ByteArray remaining_message_bytes + RECORD_HEADER_SIZE_  // Include space for header.
    synthetic.replace 0 header.bytes
    synthetic_header := RecordHeader_ synthetic
    // Overwrite record size of header.
    synthetic_header.length = remaining_message_bytes
    remaining_in_record := header.length
    while remaining_message_bytes > 0:
      m := min remaining_in_record remaining_message_bytes
      chunk := reader_.read --max_size=m
      synthetic.replace (synthetic.size - remaining_message_bytes) chunk
      remaining_message_bytes -= chunk.size
      remaining_in_record -= chunk.size
      if remaining_in_record == 0 and remaining_message_bytes != 0:
        header = RecordHeader_ (reader_.read_bytes RECORD_HEADER_SIZE_)  // Next record header.
        if header.type != content_type: throw "Unexpected content type in continued record"
        remaining_in_record = header.length
    if remaining_in_record != 0:
      // The message ended in the middle of a record.  We have to unget a
      // synthetic record header to the stream to take care of the rest of
      // the record.
      reader_.ensure 1
      unget_synthetic_header := RecordHeader_ header.bytes.copy
      unget_synthetic_header.length = remaining_in_record
      reader_.unget unget_synthetic_header.bytes
    return synthetic

  read_handshake_message_ -> none:
    packet := extract_first_message_
    tls_set_incoming_ tls_ packet 0

class CipherSuite_:
  id /int               // 16 bit cipher suite ID from RFCs 5288, 5289, 7905.
  key_size /int         // In bytes.
  iv_size /int          // In bytes.
  algorithm /int        // ALGORITHM_AES_GCM or ALGORITHM_CHACHA20_POLY1305 from lib/crypto.
  hmac_hasher /Lambda   // Lambda that creates Sha256 or Sha384 objects.
  hmac_block_size /int  // In bytes.

  constructor .id/int:
      // No suites from RFC 5246, because they have all been deprecated.
      sha_is_256 /bool := ?
      if 0x9c <= id <= 0xa7 or 0xc02b <= id <= 0xc032:
        // The AES GCM suites from RFC 5288 and RFC 5289.
        algorithm = ALGORITHM_AES_GCM
        sha_is_256 = id < 0x100
            ? id & 1 == 0
            : id & 1 == 1
        key_size = sha_is_256 ? 16 : 32  // Pick AES-128 or AES-256.
        iv_size = 4  // Called the salt in RFC 5288.
      else if 0xcca8 <= id <= 0xccae:
        // The ChaCha20-Poly1305 suites from RFC 7905.
        algorithm = ALGORITHM_CHACHA20_POLY1305
        sha_is_256 = true
        key_size = 32
        iv_size = 12  // Called the nonce in RFC 7905.
      else:
        throw "Unknown cipher suite ID: $id"
      if sha_is_256:
        hmac_hasher = :: Sha256
        hmac_block_size = Sha256.BLOCK_SIZE
      else:
        hmac_hasher = :: Sha384
        hmac_block_size = Sha384.BLOCK_SIZE

class ToitHandshake_:
  session_ /Session
  session_id_ /ByteArray := ?
  session_ticket_ /ByteArray := ?
  master_secret_ /ByteArray
  cipher_suite_ /CipherSuite_
  client_random_ /ByteArray

  constructor .session_:
    list := tison.decode session_.session_state
    session_id_ = list[0]
    session_ticket_ = list[1]
    master_secret_ = list[2]
    cipher_suite_ = CipherSuite_ list[3]
    client_random_ = ByteArray CLIENT_RANDOM_SIZE_
    tls_get_random_ client_random_

  static CLIENT_HELLO_TEMPLATE_1_ ::= #[
      22,          // Record type: HANDSHAKE_
      3, 1,        // TLS 1.0 - see comment at https://tls12.xargs.org/#client-hello/annotated
      0, 0,        // Record header size will be filled in here.
      1,           // CLIENT_HELLO_.
      0, 0, 0,     // Message size will be filled in here.
      3, 3,        // TLS 1.2.
  ]

  static CLIENT_HELLO_TEMPLATE_2_ ::= #[
      0, 2,        // Cipher suites size.
      0, 0,        // Cipher suite is filled in here.
      1,           // Compression methods length.
      0,           // No compression.
  ]

  static CHANGE_CIPHER_SPEC_TEMPLATE_ ::= #[
      20,          // Record type: CHANGE_CIPHER_SPEC_
      3, 3,        // TLS 1.2.
      0, 1,        // One byte of payload.
      1,           // 1 means change cipher spec.
  ]

  handshake -> List:
    handshake_hasher /checksum.Checksum := cipher_suite_.hmac_hasher.call
    hello := client_hello_packet_
    handshake_hasher.add hello[5..]
    sent := session_.writer_.write hello
    assert: sent == hello.size
    server_hello_packet := session_.extract_first_message_
    handshake_hasher.add server_hello_packet[5..]
    server_hello := ServerHello_ server_hello_packet

    // Session IDs are handled in RFC 4346.  Session tickets are in RFC 5077.
    // * We sent ticket, and a random session ID.  Server accepts ticket: Figure 5077-2.
    //   * Server responds with matching session ID. Shortened handshake gets
    //          us connected.  There may be a NewSessionTicket message.
    // * We sent session ID, server accepts session ID: Figure 4346-2.
    //    * Server sends no ticket extension, echoes back session ID in
    //          server hello. Shortened handshake gets us connected.
    // * We sent session ID, server responds with non-matching session ID:  Figure 4346-1, 5077-3, or 5077-4.
    //    * This means we need a full handshake which is not yet
    //          implemented in Toit. Abandon and reconnect, using MbedTLS.
    if not compare_byte_arrays_ server_hello.session_id session_id_:
      // Session ID not accepted.  Abandon and reconnect, using MbedTLS.
      throw "RESUME_FAILED"
    next_server_packet := session_.extract_first_message_
    if next_server_packet[0] == HANDSHAKE_ and next_server_packet[5] == NEW_SESSION_TICKET_:
      session_ticket_ = next_server_packet[9..]
      assert:
        message := HandshakeHeader_ next_server_packet
        message.length == session_ticket_.size
      handshake_hasher.add next_server_packet[5..]
      next_server_packet = session_.extract_first_message_

    // Generate new keys in a shortened handshake.
    key_size := cipher_suite_.key_size
    iv_size := cipher_suite_.iv_size
    bytes_needed := 2 * (key_size + iv_size)
    // RFC 5246 section 6.3.
    key_data := pseudo_random_function_ bytes_needed
        --block_size=cipher_suite_.hmac_block_size
        --secret=master_secret_
        --label="key expansion"
        --seed=(server_hello.random + client_random_)
        cipher_suite_.hmac_hasher
    partition := partition_byte_array_ key_data [key_size, key_size, iv_size, iv_size]
    write_key := KeyData_ --key=partition[0] --iv=partition[2] --algorithm=cipher_suite_.algorithm
    read_key := KeyData_ --key=partition[1] --iv=partition[3] --algorithm=cipher_suite_.algorithm
    sent = session_.writer_.write CHANGE_CIPHER_SPEC_TEMPLATE_
    assert: sent == CHANGE_CIPHER_SPEC_TEMPLATE_.size
    if next_server_packet.size != 6 or next_server_packet[0] != CHANGE_CIPHER_SPEC_ or next_server_packet[5] != 1:
      throw "Peer did not accept change cipher spec"
    server_handshake_hash := handshake_hasher.clone.get
    // https://www.rfc-editor.org/rfc/rfc5246#section-7.4.9
    server_finished_expected := pseudo_random_function_ 12
        --block_size=cipher_suite_.hmac_block_size
        --secret=master_secret_
        --label="server finished"
        --seed=server_handshake_hash
        cipher_suite_.hmac_hasher
    server_finished_expected = #[FINISHED_, 0x00, 0x00, server_finished_expected.size] + server_finished_expected
    // The client message hash includes the server handshake message.
    // We know what that message is going to be, so we can add it before
    // we receive it.
    handshake_hasher.add server_finished_expected
    client_handshake_hash := handshake_hasher.get
    // The client finished messages includes the hash of the server's.
    client_finished := pseudo_random_function_ 12
        --block_size=cipher_suite_.hmac_block_size
        --secret=master_secret_
        --label="client finished"
        --seed=client_handshake_hash
        cipher_suite_.hmac_hasher
    client_finished = #[FINISHED_, 0x00, 0x00, client_finished.size] + client_finished
    symmetric_session :=
        SymmetricSession_ session_ session_.writer_ session_.reader_ write_key read_key

    return [
        symmetric_session,
        client_finished,
        server_finished_expected,
        session_ticket_.size == 0 ? session_id_: #[],
        session_ticket_,
        master_secret_,
        cipher_suite_.id,
    ]

  client_hello_packet_ -> ByteArray:
    enough_bytes := 150 + session_ticket_.size
    if session_.server_name_: enough_bytes += session_.server_name_.size
    client_hello := ByteArray enough_bytes
    client_hello.replace 0 CLIENT_HELLO_TEMPLATE_1_
    index := CLIENT_HELLO_TEMPLATE_1_.size
    client_hello.replace index client_random_
    index += CLIENT_RANDOM_SIZE_
    if session_id_.size == 0:
      session_id_ = ByteArray 32
      tls_get_random_ session_id_
    client_hello[index++] = session_id_.size  // Session ID length.
    client_hello.replace index session_id_
    index += session_id_.size
    client_hello.replace index CLIENT_HELLO_TEMPLATE_2_
    BIG_ENDIAN.put_uint16 client_hello (index + 2) cipher_suite_.id
    index += CLIENT_HELLO_TEMPLATE_2_.size

    // Build the extensions.
    extensions := []
    add_name_extension_ extensions
    add_algorithms_extensions_ extensions
    add_session_ticket_extension_ extensions

    // Write extensions size.
    extensions_size := extensions.reduce --initial=0: | sum ext | sum + ext.size
    BIG_ENDIAN.put_uint16 client_hello index extensions_size
    index += 2
    // Write extensions.
    extensions.do:
      client_hello.replace index it
      index += it.size
    // Update size of record and message.
    record_header := RecordHeader_ client_hello
    record_header.length = index - 5
    handshake_header := HandshakeHeader_ client_hello
    handshake_header.length = index - 9
    return client_hello[..index]

  // We normally supply the hostname because multiple HTTPS servers can be on
  // the same IP.
  add_name_extension_ extensions/List -> none:
    hostname := session_.server_name_
    if hostname:
      name_extension := ByteArray hostname.size + 9
      name_extension[3] = hostname.size + 5
      name_extension[5] = hostname.size + 3
      name_extension[8] = hostname.size
      name_extension.replace 9 hostname
      extensions.add name_extension

  add_algorithms_extensions_ extensions/List -> none:
    // We don't actually have the ability to do elliptic curves in the pure
    // Toit handshake, but if we don't include this, our client hello is
    // rejected.
    extensions.add #[
        // Elliptic curve supported groups supported - numbers from
        // https://www.ietf.org/rfc/rfc8422.html#section-5.1.1
        0x00, 0x0a,  // 0x0a = elliptic curves extension.
        0x00, 0x0e,  // 14 bytes of extension data follow.
        0x00, 0x0c,  // 12 bytes of data in the curve list.
        0x00, 0x16,  // secp256k1(22) - removing this doesn't cause any test failures as far as we know.
        0x00, 0x17,  // secp256r1(23).
        0x00, 0x18,  // secp384r1(24).
        0x00, 0x19,  // secp521r1(25).
        0x00, 0x1d,  // x25519(29).
        0x00, 0x1e,  // x448(30).

        // Elliptic curve formats supported: uncompressed only.
        // From https://www.ietf.org/rfc/rfc8422.html#section-5.1.2
        // Resume to app.supabase.com fails without this.
        0x00, 0x0b, 0x00, 0x02, 0x01, 0x00,

        // Extended master secret extension - resume to Cloudflare fails without this.
        0x00, 0x17, 0x00, 0x00,

        // Signature algorithms supported.
        0x00, 0x0d,
        0x00, 0x0e,  // Length.
        0x00, 0x0c,  // Length.
        0x04, 0x01,  // rsa_pkcs1_sha256.
        0x04, 0x03,  // rsa_secp256r1_sha256.
        0x05, 0x01,  // rsa_pkcs1_sha384.
        0x05, 0x03,  // rsa_secp384r1_sha384.
        0x06, 0x01,  // rsa_pkcs1_sha512.
        0x06, 0x03,  // rsa_secp521r1_sha512.
    ]

  add_session_ticket_extension_ extensions/List -> none:
    // If we have a ticket send that.  If we don't have a ticket we send
    // an empty ticket extension to indicate we want a ticket for next time.
    // From RFC 5077 appendix A.
    ticket_extension := ByteArray session_ticket_.size + 4
    ticket_extension[1] = EXTENSION_SESSION_TICKET_
    BIG_ENDIAN.put_uint16 ticket_extension 2 session_ticket_.size
    ticket_extension.replace 4 session_ticket_
    extensions.add ticket_extension

class ServerHello_:
  extensions /Map
  random /ByteArray
  session_id /ByteArray
  cipher_suite /int

  constructor packet/ByteArray:
    header := RecordHeader_ packet
    if header.type != HANDSHAKE_ or packet[5] != SERVER_HELLO_:
      if header.type == ALERT_:
        print "Alert: $(packet[5] == 2 ? "fatal" : "warning") $(packet[6])"
        print "See https://www.rfc-editor.org/rfc/rfc4346#section-7.2"
      throw "PROTOCOL_ERROR"
    assert:
      handshake_header := HandshakeHeader_ packet
      header.length == handshake_header.length + 4  // Last line is value being asserted.
    random = packet[11..43]
    str := ""
    for i := random.size - 8; i < random.size; i++:
      if ' ' <= random[i] <= '~':
        str += "$(%c random[i])"
      else:
        break
    server_session_id_length := packet[43]
    index := 44 + server_session_id_length
    session_id = packet[44..index]
    cipher_suite = BIG_ENDIAN.uint16 packet index
    compression_method := packet[index + 2]
    if compression_method != 0: throw "PROTOCOL_ERROR"  // Compression not supported.
    index += 3
    extensions = {:}
    if index != packet.size:
      extensions_length := BIG_ENDIAN.uint16 packet index
      index += 2
      while extensions_length > 0:
        extension_type := BIG_ENDIAN.uint16 packet index
        extension_length := BIG_ENDIAN.uint16 packet index + 2
        extension := packet[index + 4..index + 4 + extension_length]
        extensions[extension_type] = extension
        index += 4 + extension_length
        extensions_length -= 4 + extension_length
    if index != packet.size: throw "PROTOCOL_ERROR"

class SymmetricSession_:
  write_keys /KeyData_
  read_keys /KeyData_
  writer_ ::= ?
  reader_ /reader.BufferedReader
  parent_ /Session

  buffered_plaintext_index_ := 0
  buffered_plaintext_ := []

  constructor .parent_ .writer_ .reader_ .write_keys .read_keys:

  write data from/int to/int --type/int=APPLICATION_DATA_ -> int:
    if to - from  == 0: return 0
    // We want to be nice to the receiver in case it is an embedded device, so we
    // don't send too large records.  This size is intended to fit in two MTUs on
    // Ethernet.
    List.chunk_up from to 2800: | from2/int to2/int length2 |
      record_header := RecordHeader_ #[type, 3, 3, 0, 0]
      record_header.length = length2
      // AES-GCM:
      // The explicit (transmitted) part of the IV (nonce) must not be reused,
      // but apart from that there are no requirements.  We just reuse the
      // sequence number, which is a common solution.
      // ChaCha20-Poly1305:
      // There is no explict (transmitted) part of the IV, so it is a
      // requirement that we use the sequence number to keep the local and
      // remote IVs in sync.  As described in RFC8446 section 5.3 the serial
      // number is xor'ed with the last 8 bytes of the 12 byte nonce.
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
      encryptor.start --authenticated_data=(sequence_number + record_header.bytes)
      // Now that we have used the actual size of the plaintext as the authentication data
      // we update the header with the real size on the wire, which includes some more data.
      record_header.length = length2 + explicit_iv.size + Aead_.TAG_SIZE
      List.chunk_up from2 to2 512: | from3 to3 length3 |
        first /bool := from3 == from2
        last /bool := to3 == to2
        plaintext := data is string
            ? data.to_byte_array from3 to3
            : data.copy from3 to3
        parts := [encryptor.add plaintext]
        if first:
          parts = [record_header.bytes, explicit_iv, parts[0]]
        if last:
          parts.add encryptor.finish
        else:
          yield  // Don't monopolize the CPU with long crypto operations.
        encrypted := byte_array_join_ parts
        written := 0
        while written < encrypted.size:
          written += writer_.write encrypted written
    return to - from

  read --expected_type/int=APPLICATION_DATA_ -> ByteArray?:
    try:
      return read_ expected_type
    finally: | is_exception exception |
      if is_exception:
        // If anything goes wrong we close the connection - don't want to give
        // anyone a second chance to probe us with dodgy data.
        parent_.close

  read_ expected_type/int -> ByteArray?:
    while true:
      if buffered_plaintext_index_ != buffered_plaintext_.size:
        result := buffered_plaintext_[buffered_plaintext_index_]
        buffered_plaintext_[buffered_plaintext_index_++] = null  // Allow GC.
        return result
      if not reader_.can_ensure 1:
        return null
      bytes := reader_.read_bytes RECORD_HEADER_SIZE_
      if not bytes: return null
      record_header := RecordHeader_ bytes
      bad_content := record_header.type != expected_type and record_header.type != ALERT_
      if bad_content or record_header.major_version != 3 or record_header.minor_version != 3: throw "PROTOCOL_ERROR $record_header.bytes"
      encrypted_length := record_header.length
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
      record_header.length = plaintext_length
      decryptor.start --authenticated_data=(sequence_number + record_header.bytes)
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
      if record_header.type == ALERT_:
        alert_data := byte_array_join_ buffered_plaintext
        if alert_data[0] != ALERT_WARNING_:
          print "See https://www.rfc-editor.org/rfc/rfc4346#section-7.2"
          throw "Fatal TLS alert: $alert_data[1]"
      else:
        assert: record_header.type == expected_type
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

/**
Generate $size random bytes using the PRF of RFC 5246.
*/
pseudo_random_function_ size/int --block_size/int --secret/ByteArray --label/string --seed/ByteArray hash_producer/Lambda -> ByteArray:
  result := []
  result_size := 0
  seed = label.to_byte_array + seed
  seeded_hmac := Hmac --block_size=block_size secret hash_producer
  a := checksum.checksum seeded_hmac.clone seed
  while result_size < size:
    hasher := seeded_hmac.clone
    hasher.add a
    a = hasher.clone.get
    hasher.add seed
    part := hasher.get
    result.add part
    result_size += part.size
  return (byte_array_join_ result)[..size]

byte_array_join_ arrays/List -> ByteArray:
  arrays_size := arrays.size
  if arrays_size == 0: return #[]
  if arrays_size == 1: return arrays[0]
  if arrays_size == 2: return arrays[0] + arrays[1]
  size := arrays.reduce --initial=0: | a b | a + b.size
  result := ByteArray size
  position := 0
  arrays.do:
    result.replace position it
    position += it.size
  return result

/// Compares byte arrays, without revealing the contents to timing attacks.
compare_byte_arrays_ a b -> bool:
  if a is not ByteArray or b is not ByteArray or a.size != b.size: return false
  accumulator := 0
  a.size.repeat: accumulator |= a[it] ^ b[it]
  return accumulator == 0

/**
Given a byte array and a list of sizes, partitions the byte array into
  slices with those sizes.
*/
partition_byte_array_ bytes/ByteArray sizes/List -> List:
  index := 0
  return sizes.map:
    index += it
    bytes[index - it .. index]

tls_token_acquire_ group:
  #primitive.tls.token_acquire

tls_token_release_ token -> none:
  #primitive.tls.token_release

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

tls_get_internals_ tls_socket -> List:
  #primitive.tls.get_internals

tls_get_random_ destination/ByteArray -> none:
  #primitive.tls.get_random
