import http
import net
import certificate_roots
import reader
import bytes

import .pack
import ..file-system-view

export Pack

open-repository url/string -> Repository:
  return Repository url

class Repository:
  url/string
  capabilits/Map

  constructor .url:
    capabilits = protocol_.load-capabilities url

  clone ref-hash/string -> Pack:
    binary-data := protocol_.load-pack capabilits url ref-hash
    return Pack binary-data ref-hash

  head -> string:
    refs := protocol_.load-refs url
    return refs[HEAD-INDICATOR_]

protocol_ ::= GitProtocol_
UPLOAD-PACK-REQUEST-CONTENT-TYPE_ ::= "pplication/x-git-upload-pack-request"
HEAD-INDICATOR_ ::= "HEAD"

// See: git help protocol-v2
//      git help protocol-http
class GitProtocol_:
  client ::= http.Client net.open --root_certificates=certificate_roots.ALL
  server-capabilities-cache ::= {:}
  version-2-header ::= http.Headers.from_map {"Git-Protocol": "version=2"}

  load-capabilities url/string:
    host := url[0..url.index-of "/"]
    return server-capabilities-cache.get host
        --if-absent=:
            capabilities-response :=
                client.get
                    --uri="https://$(url)/info/refs?service=git-upload-pack"
                    --headers=version-2-header

            if capabilities-response.status_code != 200:
              throw "Invalid repository $url, $capabilities-response.status_message"

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
    refs-response := client.post (pack-command_ "ls-refs" [] [])
      --uri="https://$(url)/git-upload-pack"
      --headers=version-2-header
      --content_type=UPLOAD-PACK-REQUEST-CONTENT-TYPE_

    if refs-response.status_code != 200:
      throw "Invalid repository $url, $refs-response.status_message"

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

  load-pack capabilitis/Map url/string ref-hash/string -> ByteArray:
    arguments := ["no-progress", "want $ref-hash"]
    if capabilitis.get "fetch" and capabilitis["fetch"].contains "shallow": arguments.add "deepen 1"
    arguments.add "done"
    fetch-response := client.post (pack-command_ "fetch" ["object-format=sha1", "agent=toit"] arguments)
        --uri="https://$url/git-upload-pack"
        --headers=version-2-header
        --content_type=UPLOAD-PACK-REQUEST-CONTENT-TYPE_

    if fetch-response.status_code != 200:
      throw "Invalid repository $url, $fetch-response.status_message"

    lines := parse-response_ fetch-response

    reading-data-lines := false
    buffer/bytes.Buffer := bytes.Buffer
    lines.do:
      if not reading-data-lines:
        if it is ByteArray and it.to-string.trim == "packfile":
          reading-data-lines = true
      else:
        if it == FLUSH-PACKET: return buffer.bytes
        if it[0] == 1: buffer.write it 1
        else if it[0] == 2: // ignore progress
        else if it[0] == 3: throw "Fatal error from server"

    throw "Missing flush packet from server"

  pack-command_ command/string capabilities/List arguments/List -> ByteArray:
    buffer := bytes.Buffer
    pack-line_ buffer "command=$command"
    if not capabilities.is-empty:
      capabilities.do: pack-line_ buffer it
      pack-delim_ buffer
    arguments.do: pack-line_ buffer it
    pack-flush_ buffer
    return buffer.bytes

  pack-line_ buffer/bytes.Buffer data/string:
    buffer.write "$(%04x data.size+5)"
    buffer.write data
    buffer.write "\n"

  pack-delim_ buffer/bytes.Buffer:
    buffer.write "0001"

  pack-flush_ buffer/bytes.Buffer:
    buffer.write "0000"

  static FLUSH-PACKET ::= 0
  static DELIMITER-PACKET ::= 1
  static RESPONSE-END-PACKET ::= 2
  parse-response_ response/http.Response -> List:
    buffer := reader.BufferedReader response.body
    lines := []
    while true:
      if not buffer.can-ensure 4: return lines
      length := int.parse --radix=16 (buffer.read-bytes 4)
      if length < 4:
        lines.add length
        continue
      if not buffer.can-ensure length:
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

