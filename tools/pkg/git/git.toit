// Copyright (C) 2024 Toitware ApS.
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

import http
import io
import net

import .pack
import ..file-system-view

export Pack

open-repository url/string -> Repository:
  return Repository url

class Repository:
  url/string
  capabilities/Map

  constructor .url:
    if not url.contains "://":
      url = url.starts-with "localhost" ? "http://$url" : "https://$url"
    capabilities = protocol_.load-capabilities url

  clone --binary ref-hash/string -> ByteArray:
    if not binary: throw "INVALID_ARGUMENT"
    return protocol_.load-pack capabilities url ref-hash

  clone ref-hash/string -> Pack:
    return Pack (clone --binary ref-hash) ref-hash

  head -> string:
    refs := protocol_.load-refs url
    return refs[HEAD-INDICATOR_]

  refs -> Map:
    return protocol_.load-refs url

protocol_ ::= GitProtocol_
UPLOAD-PACK-REQUEST-CONTENT-TYPE_ ::= "application/x-git-upload-pack-request"
HEAD-INDICATOR_ ::= "HEAD"

// See: git help protocol-v2
//      git help protocol-http
class GitProtocol_:
  network_/net.Client? := ?
  client_/http.Client? := ?
  server-capabilities-cache_/Map
  version-2-header_/http.Headers

  constructor:
    network_ = net.open
    client_ = http.Client network_
    server-capabilities-cache_ = {:}
    version-2-header_ = http.Headers.from-map {"Git-Protocol": "version=2"}

  close -> none:
    if client_:
      client_.close
      client_ = null

    if network_:
      network_.close
      network_ = null


  load-capabilities url/string:
    host := url[0..url.index-of "/"]
    return server-capabilities-cache_.get host
        --init=:
            capabilities-response :=
                client_.get
                    --uri="$(url)/info/refs?service=git-upload-pack"
                    --headers=version-2-header_

            if capabilities-response.status-code != 200:
              throw "Invalid repository $url, $capabilities-response.status-message"

            lines := parse-response_ capabilities-response
            capabilities := {:}
            lines.do:
              if it is ByteArray:
                capability/string := it.to-string
                if capability.contains "=":
                  split := capability.split "="
                  if split.size != 2: throw "Unrecognized capability pack line: $capability"
                  capabilities[split[0]] = split[1]

            capabilities

  load-refs url/string -> Map:
    refs-response := client_.post (pack-command_ "ls-refs" [] [])
        --uri="$url/git-upload-pack"
        --headers=version-2-header_
        --content-type=UPLOAD-PACK-REQUEST-CONTENT-TYPE_

    if refs-response.status-code != 200:
      throw "Invalid repository $url, $refs-response.status-message"

    lines := parse-response_ refs-response
    if lines.is-empty: throw "Invalid refs response for $url"
    refs := Map
    lines.do:
      if it == FLUSH-PACKET: return refs
      if it is ByteArray:
        line/string := it.to-string.trim
        space := line.index-of " "
        tag := line[space + 1..]
        hash := line[0..space]
        refs[tag] = hash

    throw "Missing flush packet from server"

  load-pack capabilities/Map url/string ref-hash/string -> ByteArray:
    if ref-hash == "": throw "Invalid hash"
    arguments := ["no-progress", "want $ref-hash"]
    if capabilities.contains "fetch" and capabilities["fetch"].contains "shallow": arguments.add "deepen 1"
    arguments.add "done"
    fetch-response := client_.post (pack-command_ "fetch" ["object-format=sha1", "agent=toit"] arguments)
        --uri="$url/git-upload-pack"
        --headers=version-2-header_
        --content-type=UPLOAD-PACK-REQUEST-CONTENT-TYPE_

    if fetch-response.status-code != 200:
      throw "Invalid repository $url, $fetch-response.status-message"

    lines := parse-response_ fetch-response

    reading-data-lines := false
    buffer := io.Buffer
    lines.do:
      if not reading-data-lines:
        if it is ByteArray and it.to-string.trim == "packfile":
          reading-data-lines = true
      else:
        if it is int:
          if it == FLUSH-PACKET: return buffer.bytes
          else if it == DELIMITER-PACKET: // ignore
          else if it == RESPONSE-END-PACKET: // ignore
          else: throw "Unknown special packet ($it) from server"
        else if it is ByteArray:
          if it[0] == 1: buffer.write it 1
          else if it[0] == 2: // Ignore progress.
          else if it[0] == 3: throw "Fatal error from server"
          else: throw "Unknown stream code $it[0] received from server"
        else: unreachable

    throw "Missing flush packet from server"

  pack-command_ command/string capabilities/List arguments/List -> ByteArray:
    buffer := io.Buffer
    pack-line_ buffer "command=$command"
    if not capabilities.is-empty:
      capabilities.do: pack-line_ buffer it
      pack-delim_ buffer
    arguments.do: pack-line_ buffer it
    pack-flush_ buffer
    return buffer.bytes

  pack-line_ buffer/io.Buffer data/string:
    buffer.write "$(%04x data.size+5)"
    buffer.write data
    buffer.write "\n"

  pack-delim_ buffer/io.Buffer:
    buffer.write "0001"

  pack-flush_ buffer/io.Buffer:
    buffer.write "0000"

  static FLUSH-PACKET ::= 0
  static DELIMITER-PACKET ::= 1
  static RESPONSE-END-PACKET ::= 2
  parse-response_ response/http.Response -> List:
    buffer := io.Reader.adapt response.body
    lines := []
    while true:
      if not buffer.try-ensure-buffered 4: return lines
      length := int.parse --radix=16 (buffer.read-bytes 4)
      if length < 4:
        lines.add length
        continue
      if not buffer.try-ensure-buffered length:
        throw "Premature end of input"
      lines.add (buffer.read-bytes length - 4)


class GitFileSystemView implements FileSystemView:
  content_/Map

  constructor .content_:

  get --path/List -> any:
    if path.is-empty: return null
    if path.size == 1: return get path[0]

    element := content_.get path[0]
    if not element is Map: return null

    return (GitFileSystemView element).get --path=path[1..]

  get key/string -> any:
    element := content_.get key
    if element is Map: return GitFileSystemView element
    return element

  list -> Map:
    return content_.map: | k v | if v is Map: GitFileSystemView v else: k
