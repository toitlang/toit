// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
HTTP requests for sandboxed containers (experimental).

The requests are made by the system's sandbox HTTP service, which only
  sends them to the URLs (host, port and path) of the container's network
  policy, and runs TLS for https URLs with the system's root certificates.
  The container must be started with the service on its service list and
  a network policy:

```
containers.start id --untrusted
    --services=[SandboxHttpService.SELECTOR]
    --network={"allow": ["api.example.com:443/v1/"]}
```

```
import net.sandbox-http

main:
  client := sandbox-http.open
  response := client.get "https://api.example.com/v1/status"
  print response.status-code
  print response.body.read-all.to-string
  response.close
```

Redirects are not followed: a 3xx response is returned, and a new request
  to its location is checked against the policy like any other.
*/

import io
import system.api.sandbox-network show *

service_/SandboxNetworkClient? ::= (SandboxNetworkClient SandboxHttpService.SELECTOR).open
    --if-absent=: null

/**
Opens the sandbox HTTP client. Throws if the container may not use the
  sandbox HTTP service.
*/
open -> SandboxHttpClient:
  client := service_
  if not client: throw "Sandbox HTTP unavailable"
  return SandboxHttpClient.internal_ client

class SandboxHttpClient:
  client_/SandboxNetworkClient

  constructor.internal_ .client_:

  get url/string --headers/Map?=null -> SandboxResponse:
    return request "GET" url --headers=headers

  post url/string body/io.Data --headers/Map?=null --content-type/string?=null -> SandboxResponse:
    if content-type:
      headers = headers ? headers.copy : {:}
      headers["Content-Type"] = content-type
    return request "POST" url --headers=headers --body=body

  /**
  Sends a request with the given $method to the $url (http or https).

  The $body is null, an $io.Data (a byte array or a string), or an
    $io.Reader; a reader is sent chunked, unless $content-length is given.

  Throws NETWORK_DENIED if the network policy doesn't allow the URL,
    QUOTA_EXCEEDED if the container has too many connections or made too
    many attempts, INVALID_ARGUMENT for headers the service sets (Host,
    Content-Length, ...), and CONNECT_FAILED, TLS_FAILED, TIMEOUT,
    HTTP_PROTOCOL_ERROR when the request fails.
  */
  request method/string url/string -> SandboxResponse
      --headers/Map?=null
      --body/any=null
      --content-length/int?=null:
    flat := []
    if headers: headers.do: | name value | flat.add name; flat.add value
    reader/io.Reader? := null
    if body is io.Reader:
      reader = body
    else if body != null:
      data := body as io.Data
      content-length = data.byte-size
      reader = io.Reader (ByteArray.from data)
    else if content-length == null:
      content-length = 0
    handle := client_.request method url flat content-length
    stream := SandboxHttpStream_ client_ handle
    try:
      if reader:
        while chunk := reader.read --max-size=CHUNK-SIZE:
          stream.write-chunk chunk
      stream.end-writes
      result := stream.wait-for: stream.network.response handle
      return SandboxResponse.internal_ stream result[0] result[1]
    finally: | is-exception _ |
      if is-exception: stream.close

class SandboxHttpStream_ extends SandboxStream:
  constructor client/SandboxNetworkClient handle/int:
    super client handle

/** A response of the sandbox HTTP service. */
class SandboxResponse:
  stream_/SandboxStream
  status-code/int
  /** The headers, with lower-case names; repeated headers joined with ", ". */
  headers/Map
  body/io.CloseableReader

  constructor.internal_ .stream_ .status-code flat/List:
    headers = {:}
    for i := 0; i < flat.size; i += 2:
      name := flat[i].to-ascii-lower
      value := flat[i + 1]
      headers[name] = headers.contains name ? "$headers[name], $value" : value
    body = SandboxBody_ stream_

  /** Closes the response and its connection. */
  close -> none:
    body.close
    stream_.close

class SandboxBody_ extends io.CloseableReader:
  stream_/SandboxStream

  constructor .stream_:

  // The connection is closed at the end of the body or on an error, so
  // it stops counting against the container's connection limit.
  read_ -> ByteArray?:
    if stream_.is-closed: return null
    chunk/ByteArray? := null
    try:
      chunk = stream_.read-chunk
      return chunk
    finally:
      if not chunk: stream_.close

  close_ -> none:
