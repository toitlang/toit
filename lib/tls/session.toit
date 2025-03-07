// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import crypto.aes show *
import crypto.chacha20 show *
import crypto.checksum
import crypto.hmac show Hmac
import crypto.sha show Sha256 Sha384
import encoding.tison
import io
import io show BIG-ENDIAN
import monitor
import net.x509 as x509
import tls

import .certificate
import .socket

// Record types from RFC 5246 section 6.2.1.
CHANGE-CIPHER-SPEC_ ::= 20
ALERT_              ::= 21
HANDSHAKE_          ::= 22
APPLICATION-DATA_   ::= 23

// Handshake message types from RFC 5246 section 7.4.
HELLO-REQUEST_       ::= 0
CLIENT-HELLO_        ::= 1
SERVER-HELLO_        ::= 2
NEW-SESSION-TICKET_  ::= 4
CERTIFICATE_         ::= 11
SERVER-KEY-EXCHANGE_ ::= 12
CERTIFICATE-REQUEST_ ::= 13
SERVER-HELLO-DONE_   ::= 14
CERTIFICATE-VERIFY_  ::= 15
CLIENT-KEY-EXCHANGE_ ::= 16
FINISHED_            ::= 20

ALERT-WARNING_ ::= 1
ALERT-FATAL_   ::= 2

RECORD-HEADER-SIZE_ ::= 5
CLIENT-RANDOM-SIZE_ ::= 32

EXTENSION-SERVER-NAME_            ::= 0
EXTENSION-EXTENDED-MASTER-SECRET_ ::= 23
EXTENSION-SESSION-TICKET_         ::= 35

class RecordHeader_:
  bytes /ByteArray      // At least 5 bytes.
  type -> int: return bytes[0]
  major-version -> int: return bytes[1]
  minor-version -> int: return bytes[2]
  length -> int: return BIG-ENDIAN.uint16 bytes 3
  length= value/int: BIG-ENDIAN.put-uint16 bytes 3 value

  constructor .bytes:

class HandshakeHeader_:
  bytes /ByteArray     // At least 9 bytes.  Includes the record header.
  type -> int: return bytes[5]
  length -> int: return BIG-ENDIAN.uint24 bytes 6
  length= value/int: BIG-ENDIAN.put-uint24 bytes 6 value

  constructor .bytes:

class KeyData_:
  key /ByteArray
  iv /ByteArray
  algorithm /int
  sequence-number_ /int := 0

  // Algorithm is one of ALGORITHM_AES_GCM or ALGORITHM_CHACHA20_POLY1305.
  constructor --.key --.iv --.algorithm/int:
    // Both algorithms require a 12 byte IV, so we pad.
    iv += ByteArray (12 - iv.size)

  next-sequence-number -> ByteArray:
    result := ByteArray 8
    BIG-ENDIAN.put-int64 result 0 sequence-number_++
    // We can't allow the sequence number to wrap around, because that would lead
    // to iv reuse.  In the unlikely event that we transmit so much data we
    // have to throw an exception and close the connection.
    if sequence-number_ < 0: throw "CONNECTION_EXHAUSTED"
    return result

  has-explicit-iv -> bool:
    return algorithm == ALGORITHM-AES-GCM

  new-encryptor message-iv/ByteArray -> Aead_:
    if algorithm == ALGORITHM-AES-GCM:
      return AesGcm.encryptor key message-iv
    return ChaCha20Poly1305.encryptor key message-iv

  new-decryptor message-iv/ByteArray -> Aead_:
    if algorithm == ALGORITHM-AES-GCM:
      return AesGcm.decryptor key message-iv
    return ChaCha20Poly1305.decryptor key message-iv

// TLS verifying certificates and performing asymmetric crypto.
SESSION-MODE-CONNECTING ::= 0
// TLS connected, using symmetric crypto, controlled by MbedTLS.
SESSION-MODE-MBED-TLS   ::= 1
// TLS connected, using symmetric crypto, controlled in Toit.
SESSION-MODE-TOIT       ::= 2
// TLS connection closed.
SESSION-MODE-CLOSED     ::= 3
// TLS connection did not attempt handshake yet.
SESSION-MODE-NONE       ::= 4

/**
TLS Session upgrades a reader/writer pair to a TLS encrypted communication
  channel.

The most common usage of a TLS session is for upgrading a TCP socket to secure
  TLS socket.  For that use-case see $Socket.
*/
class Session:
  static DEFAULT-HANDSHAKE-TIMEOUT ::= Duration --s=10
  is-server/bool ::= false
  certificate/Certificate?
  root-certificates/List
  handshake-timeout/Duration
  skip-certificate-verification/bool

  reader_/io.CloseableReader? := ?
  writer_/io.CloseableWriter? := ?
  server-name_/string? ::= null

  handshake-in-progress_/monitor.Latch? := null
  tls_ := null
  tls-group_/TlsGroup_? := null

  bytes-before-next-record-header_ := 0
  outgoing-partial-header_ := #[]
  closed-for-write_ := false
  outgoing-sequence-numbers-used_ := 0
  incoming-sequence-numbers-used_ := 0

  reads-encrypted_ := false
  writes-encrypted_ := false
  symmetric-session_/SymmetricSession_? := null
  state-bits_/int := ?

  static HANDSHAKE-ATTEMPTED_ ::= 1
  static SESSION-PROVIDED_    ::= 2

  /**
  Returns one of the SESSION-MODE-* constants, such as $SESSION-MODE-TOIT.
  */
  mode -> int:
    if tls_:
      if reads-encrypted_ and writes-encrypted_:
        return SESSION-MODE-MBED-TLS
      else:
        return SESSION-MODE-CONNECTING
    else:
      if symmetric-session_:
        return SESSION-MODE-TOIT
      else if state-bits_ & HANDSHAKE-ATTEMPTED_ == 0:
        return SESSION-MODE-NONE
      else:
        return SESSION-MODE-CLOSED

  /**
  Returns true if the session was successfully resumed, rather
    than going through a full handshake with asymmetric crypto.
  Returns false until the handshake is complete.
  */
  resumed -> bool:
    m := mode
    return state-bits_ & SESSION-PROVIDED_ != 0 and
        (m == SESSION-MODE-MBED-TLS or m == SESSION-MODE-TOIT)

  /**
  Creates a new TLS session at the client-side.

  If $server-name is provided, it will validate the peer certificate against
    that. If the $server-name is omitted, it will skip verification.
  The $root-certificates are used to validate the peer certificate.
  If $certificate is given, the certificate is used by the server to validate
    the authority of the client. This is not usually done on the web, where
    normally only the client verifies the server
  The handshake routine requires at most $handshake-timeout between each step
    in the handshake process.
  If $session-state is given, the handshake operation will use it to resume the
    TLS session from the previous stored session state. This can greatly
    improve the duration of a complete TLS handshake. If the session state is
    given, but rejected by the server, an error will be thrown, and the
    operation must be retried without stored session data.
  */
  constructor.client .reader_ .writer_
      --server-name/string?=null
      --.certificate=null
      --.root-certificates=[]
      --.session-state=null
      --.handshake-timeout/Duration=DEFAULT-HANDSHAKE-TIMEOUT
      --.skip-certificate-verification=false:
    server-name_ = server-name
    state-bits_ = session-state ? SESSION-PROVIDED_ : 0

  /**
  Creates a new TLS session at the server-side.

  The $root-certificates are used to validate the peer certificate.
  If $certificate is given, the certificate is used by the server to validate
    the authority of the client. This is not usually done on the web,
    where normally only the client verifies the server.
  The handshake routine requires at most $handshake-timeout between each step
    in the handshake process.
  */
  constructor.server .reader_ .writer_
      --.certificate=null
      --.root-certificates=[]
      --.handshake-timeout/Duration=DEFAULT-HANDSHAKE-TIMEOUT:
    is-server = true
    state-bits_ = 0
    skip-certificate-verification = false

  /**
  Explicitly completes the handshake step.

  This method will automatically be called by read and write if the handshake
    is not completed yet.
  */
  handshake -> none:
    state-bits_ |= HANDSHAKE-ATTEMPTED_
    if not reader_:
      throw "ALREADY_CLOSED"
    else if handshake-in-progress_:
      handshake-in-progress_.get  // Throws if an exception was set.
      return
    else if symmetric-session_ or tls-group_:
      throw "TLS_ALREADY_HANDSHAKEN"

    handshake-in-progress_ = monitor.Latch

    if session-state:
      try:
        result := (ToitHandshake_ this).handshake
        set-up-symmetric-session_ result
        // Connected.
        return
      finally: | is-exception exception |
        // If the task that is doing the handshake gets canceled,
        // we have to be careful and clean up anyway.
        critical-do:
          value := is-exception ? exception.value : null
          handshake-in-progress_.set value --exception=is-exception
          handshake-in-progress_ = null

    tls-group := is-server ? tls-group-server_ : tls-group-client_

    token := null
    token-state/monitor.ResourceState_? := null
    tls := null
    tls-state/monitor.ResourceState_? := null
    try:
      group := tls-group.use

      // We allow the VM to prevent too many concurrent
      // handshakes because they are very memory intensive.
      // We acquire a token and we must wait until the
      // token has a non-zero state before we are allowed
      // to start the handshake process. When releasing
      // the token, we notify the first waiter if any.
      token = tls-token-acquire_ group
      token-state = ResourceState_ group token
      token-state.wait
      token-state.dispose
      token-state = null

      tls = tls-create_ group server-name_
      tls-state = monitor.ResourceState_ group tls
      // TODO(kasper): It would be great to be able to set
      // the field after the successful handshake, but a
      // good chunk of methods use the field indirectly as
      // part of completing the handshake.
      tls_ = tls
      handshake_ tls-state --session-state=session-state

    finally: | is-exception exception |
      // If the task that is doing the handshake gets canceled,
      // we have to be careful and clean up anyway.
      critical-do:
        if token-state: token-state.dispose
        if tls-state: tls-state.dispose
        if is-exception: reader_ = null

        if is-exception or symmetric-session_ != null:
          // We do not need the resources any more. Either
          // because we're running in Toit mode using a
          // symmetric session or because we failed to do
          // the handshake.
          if tls: tls-close_ tls
          tls-group.unuse
          tls_ = null
        else:
          // Delay the closing of the TLS group and resource
          // until $close is called.
          tls-group_ = tls-group
          add-finalizer this:: close

        // Release the handshake token if we managed to
        // create the resource group.
        if token: tls-token-release_ token

        // Mark the handshake as no longer in progress and
        // send back any exception to whoever may be waiting
        // for the handshake to complete.
        handshake-in-progress_.set (is-exception ? exception : null)
            --exception=is-exception
        handshake-in-progress_ = null

  handshake_ tls-state/monitor.ResourceState_ --session-state/ByteArray?=null -> none:
    root-certificates.do: | root-certificate |
      if root-certificate is x509.Certificate:
        tls-add-root-certificate_ tls_ root-certificate.res_
      else:
        root := root-certificate as tls.RootCertificate
        tls-add-root-certificate_ tls_ root.ensure-parsed_.res_
    if certificate:
      tls-add-certificate_ tls_ certificate.certificate.res_ certificate.private-key certificate.password
    tls-init-socket_ tls_ null skip-certificate-verification

    while true:
      tls-handshake_ tls_
      state := tls-state.wait
      tls-state.clear-state state
      with-timeout handshake-timeout:
        flush-outgoing_
      if state == TOIT-TLS-DONE_:
        extract-key-data_
        return  // Connected.
      else if state == TOIT-TLS-WANT-READ_:
        with-timeout handshake-timeout:
          read-handshake-message_
      else if state == TOIT-TLS-WANT-WRITE_:
        // This is already handled above with flush-outgoing_
      else:
        tls-error_ tls_ state

  extract-key-data_ -> none:
    if reads-encrypted_ and writes-encrypted_:
      key-data /List? := tls-get-internals_ tls_
      if key-data != null:
        session-state = tison.encode key-data[5..9]
        write-key-data := KeyData_ --key=key-data[1] --iv=key-data[3] --algorithm=key-data[0]
        read-key-data := KeyData_ --key=key-data[2] --iv=key-data[4] --algorithm=key-data[0]
        write-key-data.sequence-number_ = outgoing-sequence-numbers-used_
        read-key-data.sequence-number_ = incoming-sequence-numbers-used_
        symmetric-session_ = SymmetricSession_ this writer_ reader_ write-key-data read-key-data

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
  session-state/ByteArray? := null

  /**
  Called after a pure-Toit handshake has completed.  This sets up the
    symmetric session and checks that the handshake checksums match.
  We have to switch to encrypted mode to receive and send the last
    two handshake messages.  We do this before knowing if the handshake
    succeeded.
  */
  set-up-symmetric-session_ handshake-result/List -> none:
    reads-encrypted_ = true
    writes-encrypted_ = true
    symmetric-session_ = handshake-result[0]
    client-finished /ByteArray := handshake-result[1]
    server-finished-expected /ByteArray := handshake-result[2]
    session-id /ByteArray := handshake-result[3]
    session-ticket /ByteArray := handshake-result[4]
    master-secret /ByteArray := handshake-result[5]
    cipher-suite-id /int := handshake-result[6]

    // Get the server finished message.  This assumes we are the client.
    server-finished := symmetric-session_.read --expected-type=HANDSHAKE_
    if not compare-byte-arrays_ server-finished-expected server-finished:
      throw "TLS_HANDSHAKE_FAILED"
    // Send the client finished message.  This assumes we are the client.
    symmetric-session_.write client-finished 0 client-finished.size --type=HANDSHAKE_

    // Update the session data for any third connection.
    session-state = tison.encode [
        session-id,
        session-ticket,
        master-secret,
        cipher-suite-id,
    ]

  write data/io.Data from/int=0 to/int=data.byte-size:
    ensure-handshaken_
    if symmetric-session_: return symmetric-session_.write data from to
    if not tls_: throw "TLS_SOCKET_NOT_CONNECTED"
    sent := 0
    while true:
      if from == to:
        flush-outgoing_
        return sent
      wrote := tls-write_ tls_ data from to
      if wrote == 0: flush-outgoing_
      if wrote < 0: throw "UNEXPECTED_TLS_STATUS: $wrote"
      from += wrote
      sent += wrote

  read:
    ensure-handshaken_
    if symmetric-session_: return symmetric-session_.read
    if not tls_: throw "TLS_SOCKET_NOT_CONNECTED"
    while true:
      res := tls-read_ tls_
      if res == TOIT-TLS-WANT-READ_:
        if not read-more_: return null
      else:
        return res

  /**
  Closes the session for write operations.

  Consider using $close instead of this method.
  */
  close-write:
    if not tls_: return
    if closed-for-write_: return
    tls-close-write_ tls_
    flush-outgoing_
    closed-for-write_ = true

  /**
  Closes the TLS session and releases any resources associated with it.
  */
  close -> none:
    if tls_:
      tls-close_ tls_
      tls_ = null
    if tls-group_:
      tls-group_.unuse
      tls-group_ = null
      remove-finalizer this  // Added when tls-group_ is set.
    if reader_:
      reader_.clear
      reader_.close
      reader_ = null
    if writer_:
      writer_.close
      writer_ = null
    symmetric-session_ = null

  ensure-handshaken_:
    // TODO(kasper): It is a bit unfortunate that the $tls_ field
    // is set while we're doing the handshaking. Because of that
    // we have to check that $handshake-in-progress_ is null
    // before we can conclude that we're already handshaken.
    if symmetric-session_ or (tls_ and not handshake-in-progress_): return
    handshake

  // This takes any data that the MbedTLS callback has deposited in the
  // outgoing-buffer_ byte array and writes it to the underlying socket.
  // During handshakes we also want to keep track of the record boundaries
  // so that we can switch to a Toit-level symmetric session when
  // handshaking is complete.  For this we need to know how many handshake
  // records were sent after encryption was activated.
  flush-outgoing_ -> none:
    // Get the outgoing data from the buffer, freeing up space for more data.
    outgoing-data := tls-take-outgoing_ tls_

    // Scan the outgoing buffer for record headers.
    size := outgoing-data.size
    for scan := 0; scan < size; :
      remain := size - scan
      if bytes-before-next-record-header_ > 0:
        skip := min remain bytes-before-next-record-header_
        scan += skip
        bytes-before-next-record-header_ -= skip
      else:
        header := outgoing-partial-header_
        addition := min
            RECORD-HEADER-SIZE_ - header.size
            remain
        if addition != 0:
          header += outgoing-data[scan .. scan + addition]
          outgoing-partial-header_ = header
          scan += addition
          if header.size == RECORD-HEADER-SIZE_:
            record-header := RecordHeader_ header
            if record-header.type == CHANGE-CIPHER-SPEC_:
              writes-encrypted_ = true
            else if writes-encrypted_:
              outgoing-sequence-numbers-used_++
              check-for-zero-explicit-iv_ record-header
            bytes-before-next-record-header_ = record-header.length
            outgoing-partial-header_ = #[]
    // All bytes from outgoing-data have been either skipped, scanned or stored
    // in outgoing-partial-header_ for later scanning, so we are done scanning.
    writer_.write outgoing-data

  check-for-zero-explicit-iv_ header/RecordHeader_ -> none:
    if header.length == 0x28 and header.bytes.size >= 13:
      // If it looks like the checksum of the handshake, encoded with
      // AES-GCM, then we check that the explicit nonce is 0.  This
      // is always the case with the current MbedTLS, but since we
      // can't reuse nonces without destroying security we would like
      // a heads-up if a new version of MbedTLS changes this default.
      if header.bytes[RECORD-HEADER-SIZE_..RECORD-HEADER-SIZE_ + 8] != #[0, 0, 0, 0, 0, 0, 0, 0]: throw "MBEDTLS_TOIT_INCOMPATIBLE"

  read-more_ -> bool:
    ba := reader_.read
    if not ba or not tls_: return false
    tls-set-incoming_ tls_ ba 0
    return true

  is-ascii_ c/int -> bool:
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
  // reassembling the messages, which are all of the APPLICATION-DATA_ type.
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
  extract-first-message_ -> ByteArray:
    if (reader_.peek-byte 0) == APPLICATION-DATA_:
      // We rarely (never?) find a record with the application data type
      // because normally we have switched to encrypted mode before this
      // happens.  In any case we lose the ability to see the message
      // structure when encryption is activated and from this point we
      // just feed data unchanged to MbedTLS.
      return reader_.read
    header := RecordHeader_ (reader_.read-bytes RECORD-HEADER-SIZE_)
    content-type := header.type
    remaining-message-bytes / int := ?
    if content-type == ALERT_:
      remaining-message-bytes = 2
    else if content-type == CHANGE-CIPHER-SPEC_:
      remaining-message-bytes = 1
      reads-encrypted_ = true
    else:
      if content-type != HANDSHAKE_:
        // If we get an unknown record type the probable reason is that
        // we are not connecting to a real TLS server.  Often we have
        // accidentally connected to an HTTP server instead.  If the
        // response looks like ASCII then put it in the error thrown -
        // it may be helpful.
        reader_.unget header.bytes
        text-end := 0
        while text-end < 100 and text-end < reader_.buffered-size and is-ascii_ (reader_.peek-byte text-end):
          text-end++
        server-reply := ""
        if text-end > 2:
          server-reply = "- server replied unencrypted:\n$(reader_.read-string text-end)"
        throw "Unknown TLS record type: $content-type$server-reply"
      if reads-encrypted_:
        incoming-sequence-numbers-used_++
        // Encrypted packet so we use the record header to determine size.
        remaining-message-bytes = header.length
      else:
        // Unencrypted, so we use the message header to determine size, which
        // enables us to reassemble messages fragmented across multiple
        // records, something MbedTLS can't do alone.
        reader_.ensure-buffered 4  // 4 byte handshake message header.
        // Big endian 24 bit handshake message size.
        remaining-message-bytes = (reader_.peek-byte 1) << 16
        remaining-message-bytes += (reader_.peek-byte 2) << 8
        remaining-message-bytes += (reader_.peek-byte 3)
        remaining-message-bytes += 4  // Encoded size does not include the 4 byte handshake header.

    // The protocol requires that records are less than 16k large, so if there is
    // a single message that doesn't fit in a record we can't defragment.  MbedTLS
    // has a lower limit, currently configured to 6000 bytes, so this isn't actually
    // limiting us.
    if remaining-message-bytes >= 0x4000: throw "TLS handshake message too large to defragment"
    // Make a synthetic record that was not on the wire.
    synthetic := ByteArray remaining-message-bytes + RECORD-HEADER-SIZE_  // Include space for header.
    synthetic.replace 0 header.bytes
    synthetic-header := RecordHeader_ synthetic
    // Overwrite record size of header.
    synthetic-header.length = remaining-message-bytes
    remaining-in-record := header.length
    while remaining-message-bytes > 0:
      m := min remaining-in-record remaining-message-bytes
      chunk := reader_.read --max-size=m
      synthetic.replace (synthetic.size - remaining-message-bytes) chunk
      remaining-message-bytes -= chunk.size
      remaining-in-record -= chunk.size
      if remaining-in-record == 0 and remaining-message-bytes != 0:
        header = RecordHeader_ (reader_.read-bytes RECORD-HEADER-SIZE_)  // Next record header.
        if header.type != content-type: throw "Unexpected content type in continued record"
        remaining-in-record = header.length
    if remaining-in-record != 0:
      // The message ended in the middle of a record.  We have to unget a
      // synthetic record header to the stream to take care of the rest of
      // the record.
      reader_.ensure-buffered 1
      unget-synthetic-header := RecordHeader_ header.bytes.copy
      unget-synthetic-header.length = remaining-in-record
      reader_.unget unget-synthetic-header.bytes
    return synthetic

  read-handshake-message_ -> none:
    packet := extract-first-message_
    tls-set-incoming_ tls_ packet 0

class CipherSuite_:
  id /int               // 16 bit cipher suite ID from RFCs 5288, 5289, 7905.
  key-size /int         // In bytes.
  iv-size /int          // In bytes.
  algorithm /int        // ALGORITHM_AES_GCM or ALGORITHM_CHACHA20_POLY1305 from lib/crypto.
  hmac-hasher /Lambda   // Lambda that creates Sha256 or Sha384 objects.
  hmac-block-size /int  // In bytes.

  constructor .id/int:
      // No suites from RFC 5246, because they have all been deprecated.
      sha-is-256 /bool := ?
      if 0x9c <= id <= 0xa7 or 0xc02b <= id <= 0xc032:
        // The AES GCM suites from RFC 5288 and RFC 5289.
        algorithm = ALGORITHM-AES-GCM
        sha-is-256 = id < 0x100
            ? id & 1 == 0
            : id & 1 == 1
        key-size = sha-is-256 ? 16 : 32  // Pick AES-128 or AES-256.
        iv-size = 4  // Called the salt in RFC 5288.
      else if 0xcca8 <= id <= 0xccae:
        // The ChaCha20-Poly1305 suites from RFC 7905.
        algorithm = ALGORITHM-CHACHA20-POLY1305
        sha-is-256 = true
        key-size = 32
        iv-size = 12  // Called the nonce in RFC 7905.
      else:
        throw "Unknown cipher suite ID: $id"
      if sha-is-256:
        hmac-hasher = :: Sha256
        hmac-block-size = Sha256.BLOCK-SIZE
      else:
        hmac-hasher = :: Sha384
        hmac-block-size = Sha384.BLOCK-SIZE

class ToitHandshake_:
  session_ /Session
  session-id_ /ByteArray := ?
  session-ticket_ /ByteArray := ?
  master-secret_ /ByteArray
  cipher-suite_ /CipherSuite_
  client-random_ /ByteArray

  constructor .session_:
    list := tison.decode session_.session-state
    session-id_ = list[0]
    session-ticket_ = list[1]
    master-secret_ = list[2]
    cipher-suite_ = CipherSuite_ list[3]
    client-random_ = ByteArray CLIENT-RANDOM-SIZE_
    tls-get-random_ client-random_

  static CLIENT-HELLO-TEMPLATE-1_ ::= #[
      22,          // Record type: HANDSHAKE_
      3, 1,        // TLS 1.0 - see comment at https://tls12.xargs.org/#client-hello/annotated
      0, 0,        // Record header size will be filled in here.
      1,           // CLIENT_HELLO_.
      0, 0, 0,     // Message size will be filled in here.
      3, 3,        // TLS 1.2.
  ]

  static CLIENT-HELLO-TEMPLATE-2_ ::= #[
      0, 2,        // Cipher suites size.
      0, 0,        // Cipher suite is filled in here.
      1,           // Compression methods length.
      0,           // No compression.
  ]

  static CHANGE-CIPHER-SPEC-TEMPLATE_ ::= #[
      20,          // Record type: CHANGE-CIPHER-SPEC_
      3, 3,        // TLS 1.2.
      0, 1,        // One byte of payload.
      1,           // 1 means change cipher spec.
  ]

  handshake -> List:
    handshake-hasher /checksum.Checksum := cipher-suite_.hmac-hasher.call
    hello := client-hello-packet_
    handshake-hasher.add hello[5..]
    session_.writer_.write hello
    server-hello-packet := session_.extract-first-message_
    handshake-hasher.add server-hello-packet[5..]
    server-hello := ServerHello_ server-hello-packet

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
    if not compare-byte-arrays_ server-hello.session-id session-id_:
      // Session ID not accepted.  Abandon and reconnect, using MbedTLS.
      throw "RESUME_FAILED"
    next-server-packet := session_.extract-first-message_
    if next-server-packet[0] == HANDSHAKE_ and next-server-packet[5] == NEW-SESSION-TICKET_:
      session-ticket_ = next-server-packet[9..]
      assert:
        message := HandshakeHeader_ next-server-packet
        message.length == session-ticket_.size
      handshake-hasher.add next-server-packet[5..]
      next-server-packet = session_.extract-first-message_

    // Generate new keys in a shortened handshake.
    key-size := cipher-suite_.key-size
    iv-size := cipher-suite_.iv-size
    bytes-needed := 2 * (key-size + iv-size)
    // RFC 5246 section 6.3.
    key-data := pseudo-random-function_ bytes-needed
        --block-size=cipher-suite_.hmac-block-size
        --secret=master-secret_
        --label="key expansion"
        --seed=(server-hello.random + client-random_)
        cipher-suite_.hmac-hasher
    partition := partition-byte-array_ key-data [key-size, key-size, iv-size, iv-size]
    write-key := KeyData_ --key=partition[0] --iv=partition[2] --algorithm=cipher-suite_.algorithm
    read-key := KeyData_ --key=partition[1] --iv=partition[3] --algorithm=cipher-suite_.algorithm
    session_.writer_.write CHANGE-CIPHER-SPEC-TEMPLATE_
    if next-server-packet.size != 6 or next-server-packet[0] != CHANGE-CIPHER-SPEC_ or next-server-packet[5] != 1:
      throw "Peer did not accept change cipher spec"
    server-handshake-hash := handshake-hasher.clone.get
    // https://www.rfc-editor.org/rfc/rfc5246#section-7.4.9
    server-finished-expected := pseudo-random-function_ 12
        --block-size=cipher-suite_.hmac-block-size
        --secret=master-secret_
        --label="server finished"
        --seed=server-handshake-hash
        cipher-suite_.hmac-hasher
    server-finished-expected = #[FINISHED_, 0x00, 0x00, server-finished-expected.size] + server-finished-expected
    // The client message hash includes the server handshake message.
    // We know what that message is going to be, so we can add it before
    // we receive it.
    handshake-hasher.add server-finished-expected
    client-handshake-hash := handshake-hasher.get
    // The client finished messages includes the hash of the server's.
    client-finished := pseudo-random-function_ 12
        --block-size=cipher-suite_.hmac-block-size
        --secret=master-secret_
        --label="client finished"
        --seed=client-handshake-hash
        cipher-suite_.hmac-hasher
    client-finished = #[FINISHED_, 0x00, 0x00, client-finished.size] + client-finished
    symmetric-session :=
        SymmetricSession_ session_ session_.writer_ session_.reader_ write-key read-key

    return [
        symmetric-session,
        client-finished,
        server-finished-expected,
        session-ticket_.size == 0 ? session-id_: #[],
        session-ticket_,
        master-secret_,
        cipher-suite_.id,
    ]

  client-hello-packet_ -> ByteArray:
    enough-bytes := 150 + session-ticket_.size
    if session_.server-name_: enough-bytes += session_.server-name_.size
    client-hello := ByteArray enough-bytes
    client-hello.replace 0 CLIENT-HELLO-TEMPLATE-1_
    index := CLIENT-HELLO-TEMPLATE-1_.size
    client-hello.replace index client-random_
    index += CLIENT-RANDOM-SIZE_
    if session-id_.size == 0:
      session-id_ = ByteArray 32
      tls-get-random_ session-id_
    client-hello[index++] = session-id_.size  // Session ID length.
    client-hello.replace index session-id_
    index += session-id_.size
    client-hello.replace index CLIENT-HELLO-TEMPLATE-2_
    BIG-ENDIAN.put-uint16 client-hello (index + 2) cipher-suite_.id
    index += CLIENT-HELLO-TEMPLATE-2_.size

    // Build the extensions.
    extensions := []
    add-name-extension_ extensions
    add-algorithms-extensions_ extensions
    add-session-ticket-extension_ extensions

    // Write extensions size.
    extensions-size := extensions.reduce --initial=0: | sum ext | sum + ext.size
    BIG-ENDIAN.put-uint16 client-hello index extensions-size
    index += 2
    // Write extensions.
    extensions.do:
      client-hello.replace index it
      index += it.size
    // Update size of record and message.
    record-header := RecordHeader_ client-hello
    record-header.length = index - 5
    handshake-header := HandshakeHeader_ client-hello
    handshake-header.length = index - 9
    return client-hello[..index]

  // We normally supply the hostname because multiple HTTPS servers can be on
  // the same IP.
  add-name-extension_ extensions/List -> none:
    hostname := session_.server-name_
    if hostname:
      name-extension := ByteArray hostname.size + 9
      name-extension[3] = hostname.size + 5
      name-extension[5] = hostname.size + 3
      name-extension[8] = hostname.size
      name-extension.replace 9 hostname
      extensions.add name-extension

  add-algorithms-extensions_ extensions/List -> none:
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

  add-session-ticket-extension_ extensions/List -> none:
    // If we have a ticket send that.  If we don't have a ticket we send
    // an empty ticket extension to indicate we want a ticket for next time.
    // From RFC 5077 appendix A.
    ticket-extension := ByteArray session-ticket_.size + 4
    ticket-extension[1] = EXTENSION-SESSION-TICKET_
    BIG-ENDIAN.put-uint16 ticket-extension 2 session-ticket_.size
    ticket-extension.replace 4 session-ticket_
    extensions.add ticket-extension

class ServerHello_:
  extensions /Map
  random /ByteArray
  session-id /ByteArray
  cipher-suite /int

  constructor packet/ByteArray:
    header := RecordHeader_ packet
    if header.type != HANDSHAKE_ or packet[5] != SERVER-HELLO_:
      if header.type == ALERT_:
        print "Alert: $(packet[5] == 2 ? "fatal" : "warning") $(packet[6])"
        print "See https://www.rfc-editor.org/rfc/rfc4346#section-7.2"
      throw "PROTOCOL_ERROR"
    assert:
      handshake-header := HandshakeHeader_ packet
      header.length == handshake-header.length + 4  // Last line is value being asserted.
    random = packet[11..43]
    str := ""
    for i := random.size - 8; i < random.size; i++:
      if ' ' <= random[i] <= '~':
        str += "$(%c random[i])"
      else:
        break
    server-session-id-length := packet[43]
    index := 44 + server-session-id-length
    session-id = packet[44..index]
    cipher-suite = BIG-ENDIAN.uint16 packet index
    compression-method := packet[index + 2]
    if compression-method != 0: throw "PROTOCOL_ERROR"  // Compression not supported.
    index += 3
    extensions = {:}
    if index != packet.size:
      extensions-length := BIG-ENDIAN.uint16 packet index
      index += 2
      while extensions-length > 0:
        extension-type := BIG-ENDIAN.uint16 packet index
        extension-length := BIG-ENDIAN.uint16 packet index + 2
        extension := packet[index + 4..index + 4 + extension-length]
        extensions[extension-type] = extension
        index += 4 + extension-length
        extensions-length -= 4 + extension-length
    if index != packet.size: throw "PROTOCOL_ERROR"

class SymmetricSession_:
  write-keys /KeyData_
  read-keys /KeyData_
  writer_ /io.Writer
  reader_ /io.Reader
  parent_ /Session

  buffered-plaintext-index_ := 0
  buffered-plaintext_ := []

  constructor .parent_ .writer_ .reader_ .write-keys .read-keys:

  write data/io.Data from/int to/int --type/int=APPLICATION-DATA_ -> int:
    if to - from  == 0: return 0
    // We want to be nice to the receiver in case it is an embedded device, so we
    // don't send too large records.  This size is intended to fit in two MTUs on
    // Ethernet.
    List.chunk-up from to 2800: | from2/int to2/int length2 |
      record-header := RecordHeader_ #[type, 3, 3, 0, 0]
      record-header.length = length2
      // AES-GCM:
      // The explicit (transmitted) part of the IV (nonce) must not be reused,
      // but apart from that there are no requirements.  We just reuse the
      // sequence number, which is a common solution.
      // ChaCha20-Poly1305:
      // There is no explict (transmitted) part of the IV, so it is a
      // requirement that we use the sequence number to keep the local and
      // remote IVs in sync.  As described in RFC8446 section 5.3 the serial
      // number is xor'ed with the last 8 bytes of the 12 byte nonce.
      iv := write-keys.iv.copy
      sequence-number /ByteArray := write-keys.next-sequence-number
      explicit-iv /ByteArray := ?
      if write-keys.has-explicit-iv:
        explicit-iv = sequence-number
        iv.replace 4 explicit-iv
      else:
        explicit-iv = #[]
        8.repeat: iv[4 + it] ^= sequence-number[it]
      encryptor := write-keys.new-encryptor iv
      encryptor.start --authenticated-data=(sequence-number + record-header.bytes)
      // Now that we have used the actual size of the plaintext as the authentication data
      // we update the header with the real size on the wire, which includes some more data.
      record-header.length = length2 + explicit-iv.size + Aead_.TAG-SIZE
      List.chunk-up from2 to2 512: | from3 to3 length3 |
        first /bool := from3 == from2
        last /bool := to3 == to2
        plaintext := ByteArray (to3 - from3)
        data.write-to-byte-array plaintext --at=0 from3 to3
        parts := [encryptor.add plaintext]
        if first:
          parts = [record-header.bytes, explicit-iv, parts[0]]
        if last:
          parts.add encryptor.finish
        else:
          yield  // Don't monopolize the CPU with long crypto operations.
        encrypted := byte-array-join_ parts
        writer_.write encrypted
    return to - from

  read --expected-type/int=APPLICATION-DATA_ -> ByteArray?:
    try:
      return read_ expected-type
    finally: | is-exception exception |
      if is-exception:
        // If anything goes wrong we close the connection - don't want to give
        // anyone a second chance to probe us with dodgy data.
        parent_.close

  read_ expected-type/int -> ByteArray?:
    while true:
      if buffered-plaintext-index_ != buffered-plaintext_.size:
        result := buffered-plaintext_[buffered-plaintext-index_]
        buffered-plaintext_[buffered-plaintext-index_++] = null  // Allow GC.
        return result
      if not reader_.try-ensure-buffered RECORD-HEADER-SIZE_:
        return null
      bytes := reader_.read-bytes RECORD-HEADER-SIZE_
      record-header := RecordHeader_ bytes
      bad-content := record-header.type != expected-type and record-header.type != ALERT_
      if bad-content or record-header.major-version != 3 or record-header.minor-version != 3: throw "PROTOCOL_ERROR $record-header.bytes"
      encrypted-length := record-header.length
      // According to RFC5246: The length MUST NOT exceed 2^14 + 1024.
      if encrypted-length > (1 << 14) + 1024: throw "PROTOCOL_ERROR"

      explicit-iv /ByteArray := ?
      iv /ByteArray := read-keys.iv.copy
      sequence-number := read-keys.next-sequence-number
      if read-keys.has-explicit-iv:
        if not reader_.try-ensure-buffered 8: return null
        explicit-iv = reader_.read-bytes 8
        iv.replace 4 explicit-iv
      else:
        explicit-iv = #[]
        8.repeat: iv[4 + it] ^= sequence-number[it]

      plaintext-length := encrypted-length - Aead_.TAG-SIZE - explicit-iv.size
      decryptor := read-keys.new-decryptor iv
      // Overwrite the length with the unpadded length before adding the header
      // to the authenticated data.
      record-header.length = plaintext-length
      decryptor.start --authenticated-data=(sequence-number + record-header.bytes)
      // Accumulate plaintext in a local to ensure that no data is read by the
      // application that has not been verified.
      buffered-plaintext := []
      while plaintext-length > 0:
        encrypted := reader_.read --max-size=plaintext-length
        if not encrypted: return null
        plaintext-length -= encrypted.size
        plain-chunk := decryptor.add encrypted
        if plain-chunk.size != 0: buffered-plaintext.add plain-chunk
      if not reader_.try-ensure-buffered Aead_.TAG-SIZE: return null
      received-tag := reader_.read-bytes Aead_.TAG-SIZE
      plain-chunk := decryptor.verify received-tag
      // Since we got here, the tag was successfully verified.
      if plain-chunk.size != 0: buffered-plaintext.add plain-chunk
      if record-header.type == ALERT_:
        alert-data := byte-array-join_ buffered-plaintext
        if alert-data[0] != ALERT-WARNING_:
          print "See https://www.rfc-editor.org/rfc/rfc4346#section-7.2"
          throw "Fatal TLS alert: $alert-data[1]"
      else:
        assert: record-header.type == expected-type
      buffered-plaintext_ = buffered-plaintext
      buffered-plaintext-index_ = 0

TOIT-TLS-DONE_ := 1 << 0
TOIT-TLS-WANT-READ_ := 1 << 1
TOIT-TLS-WANT-WRITE_ := 1 << 2

tls-group-client_ ::= TlsGroup_ false
tls-group-server_ ::= TlsGroup_ true

class TlsGroup_:
  handle_/ByteArray? := null
  is-server_/bool
  users_/int := 0
  constructor .is-server_:

  use -> ByteArray:
    users_++
    if handle_: return handle_
    return handle_ = tls-init_ is-server_

  unuse -> none:
    users_--
    if users_ == 0:
      handle := handle_
      handle_ = null
      tls-deinit_ handle

/**
Generate $size random bytes using the PRF of RFC 5246.
*/
pseudo-random-function_ size/int --block-size/int --secret/ByteArray --label/string --seed/ByteArray hash-producer/Lambda -> ByteArray:
  result := []
  result-size := 0
  seed = label.to-byte-array + seed
  seeded-hmac := Hmac --block-size=block-size secret hash-producer
  a := checksum.checksum seeded-hmac.clone seed
  while result-size < size:
    hasher := seeded-hmac.clone
    hasher.add a
    a = hasher.clone.get
    hasher.add seed
    part := hasher.get
    result.add part
    result-size += part.size
  return (byte-array-join_ result)[..size]

byte-array-join_ arrays/List -> ByteArray:
  arrays-size := arrays.size
  if arrays-size == 0: return #[]
  if arrays-size == 1: return arrays[0]
  if arrays-size == 2: return arrays[0] + arrays[1]
  size := arrays.reduce --initial=0: | a b | a + b.size
  result := ByteArray size
  position := 0
  arrays.do:
    result.replace position it
    position += it.size
  return result

/// Compares byte arrays, without revealing the contents to timing attacks.
compare-byte-arrays_ a b -> bool:
  if a is not ByteArray or b is not ByteArray or a.size != b.size: return false
  accumulator := 0
  a.size.repeat: accumulator |= a[it] ^ b[it]
  return accumulator == 0

/**
Given a byte array and a list of sizes, partitions the byte array into
  slices with those sizes.
*/
partition-byte-array_ bytes/ByteArray sizes/List -> List:
  index := 0
  return sizes.map:
    index += it
    bytes[index - it .. index]

tls-token-acquire_ group:
  #primitive.tls.token-acquire

tls-token-release_ token -> none:
  #primitive.tls.token-release

tls-init_ is-server/bool:
  #primitive.tls.init

tls-deinit_ group:
  #primitive.tls.deinit

tls-create_ group hostname:
  #primitive.tls.create

tls-add-root-certificate_ group cert:
  #primitive.tls.add-root-certificate

tls-error_ socket error:
  #primitive.tls.error

tls-init-socket_ tls-socket transport-id skip-certificate-verification:
  #primitive.tls.init-socket

tls-handshake_ tls-socket:
  #primitive.tls.handshake

tls-read_ tls-socket:
  #primitive.tls.read

tls-write_ tls-socket bytes from to:
  #primitive.tls.write

tls-close-write_ tls-socket:
  #primitive.tls.close-write

tls-close_ tls-socket:
  #primitive.tls.close

tls-add-certificate_ tls-socket public-byte-array private-byte-array password:
  #primitive.tls.add-certificate

tls-set-incoming_ tls-socket byte-array from:
  #primitive.tls.set-incoming

tls-take-outgoing_ tls-socket -> ByteArray:
  #primitive.tls.take-outgoing

tls-get-internals_ tls-socket -> List:
  #primitive.tls.get-internals

tls-get-random_ destination/ByteArray -> none:
  #primitive.tls.get-random
