// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

/**
Variant H of the sandbox network services (experimental): HTTP/1.1
  requests, made by the provider, to URLs the container's network
  policy allows (host, port and path).

A small HTTP client of its own (one request per connection, no
  redirects): the service writes the request line and the headers that
  frame the request (Host, Connection, Content-Length or Transfer-Encoding)
  itself, and parses the response head with bounds before the client sees
  any of it.
*/

import io
import system.api.sandbox-network show SandboxHttpService CHUNK-SIZE

import .core
import .policy

MAX-HEADERS ::= 32
MAX-HEAD-SIZE ::= 4096
MAX-METHOD-SIZE ::= 16

// Request headers the service sets or that change the framing.
FORBIDDEN-HEADERS_ ::= {
  "host", "connection", "content-length", "transfer-encoding", "te",
  "trailer", "upgrade", "keep-alive", "expect", "proxy-connection",
  "proxy-authorization",
}

class SandboxHttpServiceProvider extends SandboxNetworkProvider:
  constructor core/SandboxNetworkCore:
    super "system/sandbox-network/http" core
    provides SandboxHttpService.SELECTOR --handler=this

  handle-open index/int arguments/any --gid/int --client/int -> any:
    if index == SandboxHttpService.RESPONSE-INDEX:
      stream := stream_ client arguments
      if stream is not HttpConnection: throw "INVALID_ARGUMENT"
      return (stream as HttpConnection).response
    if index != SandboxHttpService.REQUEST-INDEX: throw "INVALID_ARGUMENT"
    if arguments is not List or arguments.size != 5: throw "WRONG_OBJECT_TYPE"
    method := arguments[0]
    url := arguments[1]
    headers := arguments[2]
    length := arguments[3]
    ids := arguments[4]
    if method is not string or url is not string or headers is not List
        or (length != null and length is not int) or (ids != null and ids is not List):
      throw "WRONG_OBJECT_TYPE"
    if length and length < 0: throw "INVALID_ARGUMENT"
    if not is-token_ method MAX-METHOD-SIZE: throw "INVALID_ARGUMENT"
    head-lines := check-headers_ headers
    parsed := parse-url_ url
    host/string := parsed[1]
    port/int := parsed[2]
    path/string := parsed[3]
    grant := core.grant gid
    if not grant.allows host port --path=path: throw "NETWORK_DENIED"
    default-port := parsed[0] ? 443 : 80
    host-header := port == default-port ? host : "$host:$port"
    head := "$method $path HTTP/1.1\r\nHost: $host-header\r\nConnection: close\r\n$head-lines"
    if length:
      head += "Content-Length: $length\r\n\r\n"
    else:
      head += "Transfer-Encoding: chunked\r\n\r\n"
    roots := parsed[0] ? (core.tls-roots client ids grant host port --path=path) : []
    return open-stream_ grant:
      HttpConnection this client core grant host port parsed[0]
          --roots=roots
          --head=head
          --content-length=length
          --head-request=(method == "HEAD")

  /**
  Checks the flat list of request $headers and returns them as header
    lines. Throws INVALID_ARGUMENT if there are too many, they are too
    large, malformed, or ones the service sets.
  */
  static check-headers_ headers/List -> string:
    if headers.size % 2 != 0 or headers.size > 2 * MAX-HEADERS: throw "INVALID_ARGUMENT"
    buffer := io.Buffer
    for i := 0; i < headers.size; i += 2:
      name := headers[i]
      value := headers[i + 1]
      if name is not string or value is not string: throw "WRONG_OBJECT_TYPE"
      if not is-token_ name 64: throw "INVALID_ARGUMENT"
      if FORBIDDEN-HEADERS_.contains name.to-ascii-lower: throw "INVALID_ARGUMENT"
      value.do --runes: | c |
        if c < ' ' and c != '\t' or c == 0x7f: throw "INVALID_ARGUMENT"
      buffer.write "$name: $value\r\n"
      if buffer.size > MAX-HEAD-SIZE: throw "INVALID_ARGUMENT"
    return buffer.bytes.to-string

  /**
  Parses an http or https $url. Returns a list of whether it is https, the
    host, the port and the path (with the query). Throws INVALID_ARGUMENT.
  */
  static parse-url_ url/string -> List:
    secure := false
    rest := ?
    lower := url.to-ascii-lower
    if lower.starts-with "https://":
      secure = true
      rest = url[8..]
    else if lower.starts-with "http://":
      rest = url[7..]
    else:
      throw "INVALID_ARGUMENT"
    slash := rest.index-of "/"
    authority := slash < 0 ? rest : rest[..slash]
    path := slash < 0 ? "/" : rest[slash..]
    hash := path.index-of "#"
    if hash >= 0: path = path[..hash]
    if authority.contains "@" or authority.is-empty: throw "INVALID_ARGUMENT"
    port := secure ? 443 : 80
    colon := authority.index-of ":"
    host := authority
    if colon >= 0:
      host = authority[..colon]
      port = int.parse authority[colon + 1..] --if-error=: throw "INVALID_ARGUMENT"
      if not 1 <= port <= 65535: throw "INVALID_ARGUMENT"
    return [secure, host.to-ascii-lower, port, path]

  // A token of RFC 9110: visible ASCII but delimiters.
  static is-token_ text/string max/int -> bool:
    if text.is-empty or text.size > max: return false
    text.do --runes: | c |
      if c <= ' ' or c >= 0x7f or "\"(),/:;<=>?@[\\]{}".contains (string.from-rune c):
        return false
    return true

/**
An HTTP request: the request head and the client's body go out (the body
  framed by the content length or chunked), the response head is parsed
  here, and the response body is handed to the client.
*/
class HttpConnection extends SandboxConnection:
  head_/string
  content-length_/int?
  no-body_/bool
  sent_/int := 0
  response_/List? := null

  constructor provider client core grant host port secure/bool
      --roots/List
      --head/string --content-length/int? --head-request/bool:
    head_ = head
    content-length_ = content-length
    no-body_ = head-request
    timeout := grant.timeout-ms
    super provider client core grant host port secure --roots=roots
        --deadline-ms=(timeout == 0 ? null : timeout)

  // The response-bytes limit of the policy (0: none).
  too-large_ size/int -> bool:
    limit := grant.response-bytes
    return limit != 0 and size > limit

  response -> List?:
    if response_: return response_
    if error_: throw error_
    client-waits_ = true
    return null

  write-head_ -> none:
    throttle_ head_.size
    socket_.out.write head_

  write-data_ data/ByteArray -> none:
    sent_ += data.size
    if content-length_:
      if sent_ > content-length_: throw "INVALID_ARGUMENT"
      socket_.out.write data
    else:
      socket_.out.write "$(%x data.size)\r\n"
      socket_.out.write data
      socket_.out.write "\r\n"

  finish-data_ -> none:
    if content-length_:
      if sent_ != content-length_: throw "INVALID_ARGUMENT"
    else:
      socket_.out.write "0\r\n\r\n"

  reader_ -> none:
    in := socket_.in
    status := 100
    headers/List := []
    head-size := 0
    // Skip interim (1xx) responses.
    while 100 <= status <= 199:
      line := read-line_ in head-size
      head-size += line.size
      parts := line.split " "
      if parts.size < 2 or not parts[0].starts-with "HTTP/1.": throw "HTTP_PROTOCOL_ERROR"
      status = int.parse parts[1] --if-error=: throw "HTTP_PROTOCOL_ERROR"
      if not 100 <= status <= 999: throw "HTTP_PROTOCOL_ERROR"
      if status == 101: throw "HTTP_PROTOCOL_ERROR"  // No upgrades.
      headers = []
      while true:
        line = read-line_ in head-size
        head-size += line.size + 2
        if line.is-empty: break
        if headers.size >= 2 * MAX-HEADERS: throw "HTTP_PROTOCOL_ERROR"
        colon := line.index-of ":"
        if colon <= 0: throw "HTTP_PROTOCOL_ERROR"
        headers.add line[..colon]
        headers.add line[colon + 1..].trim
    response_ = [status, headers]
    changed_
    if no-body_ or status == 204 or status == 304:
      end_
      return
    encoding := header_ headers "transfer-encoding"
    if encoding and (encoding.to-ascii-lower.contains "chunked"):
      read-chunked_ in
    else if length := header_ headers "content-length":
      size := int.parse length --if-error=: throw "HTTP_PROTOCOL_ERROR"
      if too-large_ size: throw "RESPONSE_TOO_LARGE"
      read-sized_ in size
    else:
      read-sized_ in null
    end_

  static header_ headers/List name/string -> string?:
    for i := 0; i < headers.size; i += 2:
      if headers[i].to-ascii-lower == name: return headers[i + 1]
    return null

  // Reads a line of the head (without the CRLF); the head must fit in
  // $MAX-HEAD-SIZE.
  static read-line_ in/io.Reader used/int -> string:
    limit := MAX-HEAD-SIZE - used
    if limit <= 0: throw "HTTP_PROTOCOL_ERROR"
    newline := in.index-of '\n' --to=limit
    if newline < 0: throw "HTTP_PROTOCOL_ERROR"
    line := (in.read-bytes newline + 1).to-string-non-throwing
    return line.trim --right

  // Hands $size bytes (all until the end of the stream if null) to the
  // client.
  read-sized_ in/io.Reader size/int? -> none:
    received := 0
    while size == null or received < size:
      max := size == null ? CHUNK-SIZE : min CHUNK-SIZE (size - received)
      data := in.read --max-size=max
      if not data:
        if size != null: throw "CONNECTION_FAILED"
        return
      received += data.size
      if too-large_ received: throw "RESPONSE_TOO_LARGE"
      deliver_ data

  read-chunked_ in/io.Reader -> none:
    received := 0
    while true:
      line := read-line_ in 0
      semicolon := line.index-of ";"
      if semicolon >= 0: line = line[..semicolon]
      size := int.parse line.trim --radix=16 --if-error=: throw "HTTP_PROTOCOL_ERROR"
      if size < 0: throw "HTTP_PROTOCOL_ERROR"
      if size == 0:
        // Skip the trailer.
        while not (read-line_ in 0).is-empty: null
        return
      received += size
      if too-large_ received: throw "RESPONSE_TOO_LARGE"
      while size > 0:
        data := in.read --max-size=(min size CHUNK-SIZE)
        if not data: throw "CONNECTION_FAILED"
        size -= data.size
        deliver_ data
      if (read-line_ in 0) != "": throw "HTTP_PROTOCOL_ERROR"
