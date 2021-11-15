// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import reader show *
import writer show *

/**
HTTP client library for HTTP v1.1 request/responses.

# HTTP

Example for creating an unsecure HTTP connection.
```
import net
import http

main:
  network_interface := net.open

  host := "www.google.com"
  socket := network_interface.tcp_connect host 80

  connection := http.Connection socket host
  request := connection.new_request "GET" "/"
  response := request.send

  bytes := 0
  while data := response.read:
    bytes += data.size

  print "Read $bytes bytes from http://$host/"
```

# HTTPS

Example for creating a secure HTTPS connection, encrypted using TLS.

For a TLS connection to be fully verified, a trusted root certificate must be added to
  the TLS socket.  Add the package with: toit pkg install github.com/toitware/toit-cert-roots

```
import certificate_roots  // From package toit-cert-roots.
import net
import net.x509 as net
import http
import tls

main:
  network_interface := net.open

  host := "www.google.com"
  tcp := network_interface.tcp_connect host 443

  socket := tls.Socket.client tcp
    --server_name=host
    --root_certificates=[certificate_roots.GLOBALSIGN_ROOT_CA]

  connection := http.Connection socket host
  request := connection.new_request "GET" "/"
  response := request.send

  bytes := 0
  while data := response.read:
    bytes += data.size

  print "Read $bytes bytes from https://$host/"
```
*/

class Headers:
  headers_ := Map

  /**
  Returns a single string value for the header or null if the header is not
    present.  If there are multiple values, the last value is returned.
  */
  single key -> string?:
    key = ascii_normalize_ key
    if not headers_.contains key: return null
    values := headers_[key]
    return values[values.size - 1]

  /**
  Does ASCII case independent match of whether a key has a value.
  */
  matches key/string value/string -> bool:
    from_headers := single key
    if not from_headers: return false
    return from_headers == value or (ascii_normalize_ from_headers) == (ascii_normalize_ value)

  /**
  Does ASCII case independent match of whether a header value starts with a prefix.
  Returns false if the header is not present.  Only checks the last header if there are
    several of the same name.
  */
  starts_with key/string prefix/string -> bool:
    from_headers := single key
    if not from_headers: return false
    return from_headers.starts_with prefix or (ascii_normalize_ from_headers).starts_with (ascii_normalize_ prefix)

  /**
  Returns a list of string values for the header.
  */
  get key/string -> List?:
    return headers_[ascii_normalize_ key]

  /**
  Used to set headers that have only one value.
  */
  set key/string value/string -> none:
    headers_[ascii_normalize_ key] = [value]

  /**
  Used to set headers that can have multiple values.
  */
  add key/string value/string -> none:
    key = ascii_normalize_ key
    headers_.get key
      --if_present=: it.add value
      --if_absent=:  headers_[key] = [value]

  write_to writer -> none:
    headers_.do: | key values |
      values.do: | value |
        writer.write key
        writer.write ": "
        writer.write value
        writer.write "\r\n"

  // Camel-case a string.  Only works for ASCII in accordance with the HTTP
  // standard.  If the string is already camel cased (the norm) then no
  // allocation occurs.
  ascii_normalize_ str:
    alpha := false  // Was the previous character an alphabetic (ASCII) letter.
    ba := null  // Allocate byte array later if needed.
    str.size.repeat:
      char := str.at --raw it
      problem := alpha ? (is_ascii_upper_case_ char) : (is_ascii_lower_case_ char)
      if problem and not ba:
        ba = ByteArray str.size
        str.write_to_byte_array ba 0 it 0
      if ba:
        ba[it] = problem ? (char ^ 32) : char
      alpha = is_ascii_alpha_ char
    if not ba: return str
    return ba.to_string

  is_ascii_upper_case_ char:
    return 'A' <= char <= 'Z'

  is_ascii_lower_case_ char:
    return 'a' <= char <= 'z'

  is_ascii_alpha_ char:
    return is_ascii_lower_case_ char or is_ascii_upper_case_ char

class Connection:
  socket_ := ?
  host_ := ?
  reader_ := ?

  constructor .socket_ .host_="":
    reader_ = BufferedReader socket_

  reader:
    result := reader_
    reader_ = null
    return result

  new_request method url:
    return Request this (Writer socket_) method url

  get url:
    return new_request "GET" url

  read_request:
    return read_request_

  is_connected:
    return socket_.is_connected

  close:
    return socket_.close

  index_or_throw_ character:
    index := reader_.index_of character
    if not index:
      throw "UNEXPECTED_END_OF_READER"
    return index

  // Gets the next request from the client. If the client closes the
  // connection, returns null.
  read_request_:
    index_of_first_space := reader_.index_of ' '
    if not index_of_first_space: return null
    method := reader_.read_string (index_of_first_space)
    reader_.skip 1
    path := reader_.read_string (reader_.index_of_or_throw ' ')
    reader_.skip 1
    version := reader_.read_string (reader_.index_of_or_throw '\r')
    reader_.skip 1
    if reader_.read_byte != '\n': throw "FORMAT_ERROR"

    headers := read_headers_

    return Request this reader_ method path version headers

  read_response_:
    version := reader_.read_string (reader_.index_of_or_throw ' ')
    reader_.skip 1
    status_code := int.parse (reader_.read_string (reader_.index_of_or_throw ' '))
    reader_.skip 1
    status_message := reader_.read_string (reader_.index_of_or_throw '\r')
    reader_.skip 1
    if reader_.read_byte != '\n': throw "FORMAT_ERROR"

    headers := read_headers_
    reader := reader_

    // The only transfer encodings we support are 'identity' and 'chunked',
    // which are both required by HTTP/1.1.
    TE := "Transfer-Encoding"
    if headers.single TE:
      if headers.starts_with TE "chunked":
        reader = ChunkedReader_ reader
      else if not headers.matches TE "identity":
        throw "No support for $TE: $(headers.single TE)"

    return Response this reader version status_code status_message headers

  // Optional whitespace is spaces and tabs.
  is_whitespace_ char:
    return char == ' ' or char == '\t'

  read_headers_:
    headers := Headers

    while (reader_.byte 0) != '\r':
      if is_whitespace_ (reader_.byte 0):
        // Line folded headers are deprecated in RFC 7230 and we don't support
        // them.
        throw "FOLDED_HEADER"
      key := reader_.read_string (reader_.index_of ':')
      reader_.skip 1

      while is_whitespace_(reader_.byte 0): reader_.skip 1

      value := reader_.read_string (reader_.index_of '\r')
      reader_.skip 1
      if reader_.read_byte != '\n': throw "FORMAT_ERROR"

      headers.add key value

    reader_.skip 1
    if reader_.read_byte != '\n': throw "FORMAT_ERROR"

    return headers

class Request implements Reader:
  connection_ := ?
  reader_ := null
  writer_ := null

  read_ := 0
  length_ := null

  method/string := ?
  path/string := ?
  version/string ::= "HTTP/1.1"
  headers/Headers? := Headers
  body := null

  // Outgoing request to an HTTP server, we are acting like a browser.
  constructor .connection_ .writer_ .method .path:
    headers.set "Host" connection_.host_

  // Incoming request from an HTTP client like a browser, we are the server.
  constructor .connection_ .reader_ .method .path .version .headers:
    length := headers.single("Content-Length")
    if length: length_ = int.parse length
    TE ::= "Transfer-Encoding"
    transfer_encoding := headers.single(TE)
    if transfer_encoding:
      if headers.starts_with TE "chunked":
        reader_ = ChunkedReader_ (BufferedReader reader_)
      else if not headers.matches TE "identity":
        throw "No support for $TE: $(headers.single(TE))"

  send:
    connection_.socket_.set_no_delay false
    if body: headers.set "Content-Length" body.size.stringify
    write_headers_
    if body: writer_.write body
    connection_.socket_.set_no_delay true
    return connection_.read_response_

  read -> ByteArray?:
    if read_ == length_: return null
    data := reader_.read
    if not data: return data
    read_ += data.size
    return data

  response:
    if not reader_: throw "cannot respond to outgoing request"
    return Response connection_ (Writer connection_.socket_)

  write_headers_ -> none:
    if not headers: return
    writer_.write "$method $path HTTP/1.1\r\n"
    headers.write_to writer_
    writer_.write "\r\n"
    headers = null

  should_web_socket_upgrade:
    return headers.matches "Connection" "Upgrade" and headers.matches "Upgrade" "Websocket"

class DetachedSocket:
  reader_ := ?
  writer_ := ?
  socket_ := ?

  constructor .reader_ .socket_:
    writer_ = Writer socket_

  read:
    return reader_.read

  write data from = 0 to = data.size:
    return writer_.write data from to

  close_write:
    return socket_.close_write

  close:
    return socket_.close

  is_connected:
    return socket_.is_connected

class Response implements Reader:
  connection_ := ?
  reader_ := null
  writer_ := null

  read_ := 0
  length_ := null

  headers := Headers
  version := "HTTP/1.1"
  status_code := 200
  status_message := "OK"
  body := null

  constructor .connection_ .writer_:

  constructor .connection_ .reader_ .version .status_code .status_message .headers:
    length := headers.single("Content-Length")
    if length: length_ = int.parse length

  send:
    connection_.socket_.set_no_delay false
    if body: headers.set "Content-Length" body.size.stringify
    write_headers_
    if body:
      writer_.write body
    connection_.socket_.set_no_delay true

  // Return a reader & writer object, used to send raw data on the connection.
  detach:
    return DetachedSocket reader_ connection_.socket_

  read:
    if read_ == length_: return null
    data := reader_.read
    if not data: return data
    read_ += data.size
    return data

  write_headers_ -> none:
    if not headers: return
    writer_.write "$version $status_code $status_message\r\n"
    headers.write_to writer_
    writer_.write "\r\n"
    headers = null

// Chunks are separated by \r\n<hex number>\r\n
WAITING_FOR_CR1_ ::= 0
WAITING_FOR_LF1_ ::= 1
READING_NUMBER_  ::= 2
WAITING_FOR_LF2_ ::= 3
READING_CHUNK_   ::= 4
DONE_            ::= 5

// This is an adapter that converts a chunked stream (RFC 2616) to a stream of
// just the payload bytes. It takes a BufferedReader as a constructor argument,
// and acts like a Socket or TlsSocket, having one method, called read, which
// returns ByteArrays.  End of stream is indicated with a null return value
// from read.
class ChunkedReader_:
  reader_ := ?
  left_in_chunk_ := 0 // How much more raw data we are waiting for before the next size line.
  state_ := READING_NUMBER_

  constructor .reader_:

  // Return the underlying reader, which may have buffered up data.
  detach:
    return reader_

  read:
    while true:
      if state_ == DONE_: return null
      if state_ == READING_CHUNK_:
        result := reader_.read --max_size=left_in_chunk_
        left_in_chunk_ -= result.size
        if left_in_chunk_ == 0: state_ = WAITING_FOR_CR1_
        return result
      c := reader_.read_byte
      if state_ == WAITING_FOR_CR1_:
        if c != '\r': throw "PROTOCOL_ERROR"
        state_ = WAITING_FOR_LF1_
      else if state_ == WAITING_FOR_LF1_:
        if c != '\n': throw "PROTOCOL_ERROR"
        left_in_chunk_ = 0
        state_ = READING_NUMBER_
      else if state_ == READING_NUMBER_:
        // Time to read a hex number that tells us the size of the next chunk.
        if c == '\r':
          state_ = WAITING_FOR_LF2_
        else if 'a' <= c <= 'f' or 'A' <= c <= 'F':
          left_in_chunk_ <<= 4
          left_in_chunk_ += 9 + (c & 7)
        else if '0' <= c <= '9':
          left_in_chunk_ <<= 4
          left_in_chunk_ += c & 0xf
        else:
          throw "PROTOCOL_ERROR"
      else:
        assert: state_ == WAITING_FOR_LF2_
        if c != '\n': throw "PROTOCOL_ERROR"
        state_ = READING_CHUNK_
        // End is indicated by a zero hex length.
        if left_in_chunk_ == 0:
          state_ = DONE_
