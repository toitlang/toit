import http
import host.file
import host.directory
import host.os
import net
import certificate_roots
import reader
import bytes
import binary
import zlib
import encoding.hex
import encoding.json
import crypto.sha1


open-repository url/string -> Repository:
  return Repository url

class Repository:
  url/string
  capabilits/Map

  constructor .url:
    capabilits = protocol_.load-capabilities url

  clone ref-hash/string -> Pack:
    binary-data := protocol_.load-pack capabilits url ref-hash
    print binary-data.size
    return Pack binary-data ref-hash

  head -> string:
    refs := protocol_.load-refs url
    return refs[HEAD-INDICATOR_]

class Pack:
  version/int
  binary-data_/ByteArray
  content_ := {:}

  constructor .binary-data_ ref-hash/string:
    // see: git help format-pack
    if "PACK" != binary-data_[0..4].to-string-non-throwing:
      throw "Invalid pack file"
    version = binary.BIG-ENDIAN.uint32 binary-data_ 4
    if version > 2: throw "Unsuported pack version $version"

    content_ = parse-binary-data_ binary-data_ ref-hash

  /**
  Expand the pack file to location on disk
  */
  expand path/string:
    expand_ path content_

  /**
  Save the compressed pack file to location on disk
  */
  save path/string:
    file.write_content binary-data_ --path=path

  /**
  Returns the extracted data as a memory structure, where each entry in the map is either a file or a directory.
    If the value is a $Map then the entry is a sub-directory and if the value is a $ByteArray, the
    entry is a file. In either case, the key is the name of the file/directory
  */
  content -> Map: return content_

  static expand_ path m/Map:
    directory.mkdir --recursive path
    m.do: | name/string value/any |
      if value is ByteArray:
        file.write_content value --path="$path/$name"
      else:
        expand_ "$path/name" value

  static TYPE_COMMIT_ ::= 1
  static TYPE_TREE_ ::= 2
  static TYPE_BLOB_ ::= 3
  static TYPE_TAG_ ::= 4
  static TYPE_OFS_DELTA_ ::= 6
  static TYPE_REF_DELTA_ ::= 7

  static parse-binary-data_ binary-data/ByteArray ref-hash/string -> Map:
    num-entries := binary.BIG-ENDIAN.uint32 binary-data 8

    offset := 12
    objects := {:}
    top-tree/ByteArray? := null
    num-entries.repeat:
      uncompress-size := 0
      entry-type/int? := null
      header-shift := 4

      while true:
        header-byte := binary-data[offset++]
        if not entry-type:
          entry-type = (header-byte & 0b111_0000) >> 4
          uncompress-size = header-byte& 0b1111
        else:
          uncompress-size |= (header-byte& 0b0111_1111) << header-shift
          header-shift += 7
        if header-byte& 0b1000_0000 == 0: break

      if entry-type == TYPE_COMMIT_ or entry-type == TYPE_TREE_ or
         entry-type == TYPE_BLOB_ or entry-type == TYPE_TAG_:
         // undeltified representation
        read := read-uncompressed_ uncompress-size binary-data[offset..]
        offset += read[0]
        entry-data := read[1]

        if entry-type == TYPE_COMMIT_:
          entry-hash := hash-entry "commit" uncompress_size entry-data
          if (hex.encode entry-hash) == ref-hash:
            top-tree = hex.decode entry-data[5..45].to-string

        if entry-type == TYPE_TREE_:
          entry-hash := hash-entry "tree" uncompress_size entry-data
          objects[entry-hash] = TreeEntry_.parse entry-data

        if entry-type == TYPE_BLOB_:
          entry-hash := hash-entry "blob" uncompress_size entry-data
          objects[entry-hash] = entry-data

        if entry-type == TYPE_TAG_:
          // Ignore

      // deltified representation
      if entry-type == TYPE_OFS_DELTA_:
        throw "Unsurported delta type: ofs"

      if entry-type == TYPE_REF_DELTA_:
        base-hash := binary-data[offset..offset+20]
        offset = offset + 20
        read := read-uncompressed_ uncompress_size binary-data[offset..]
        offset += read[0]
        delta-data := read[1]

        blob := extract-refs_ objects[base-hash] delta-data
        entry-hash := hash-entry "blob" blob.size blob
        objects[entry-hash] = blob

    return build-tree objects top-tree

  static read-uncompressed_ uncompressed-size/int input/ByteArray -> List:
    decoder := zlib.Decoder
    try:
      buffer := bytes.Buffer
      written := 0

      while true:
        written += decoder.write --no-wait input[written..]
        buffer.write (decoder.reader.read --no-wait)
        if buffer.size >= uncompressed-size: break

      if buffer.size != uncompressed-size:
        throw "Invalid entry, expected $uncompressed-size bytes, but got $buffer.size"
      return [written, buffer.bytes]
    finally:
      decoder.close

  static read-size-encoding_ data -> List:
    offset := 0
    shift := 1
    size := 0
    while true:
      byte := data[offset++]
      size |= (byte & 0b0111_1111) << shift
      shift += 7
      if byte & 0b1000_0000 == 0: break
    return [offset, size]

  static extract-refs_ base-data/ByteArray delta-data/ByteArray -> ByteArray:
    read := read-size-encoding_ delta-data
    offset := read[0]
    base-size := read[1]

    read = read-size-encoding_ delta-data[offset..]
    offset += read[0]
    reconstructed-size := read[1]

    buffer := bytes.Buffer
    while offset < delta-data.size:
      control := delta-data[offset++]
      if control & 0b1000_0000 == 0:
        size := control & 0b0111_1111
        buffer.write delta-data[offset..offset+size]
        offset += size
      else:
        base-offset := 0
        size := 0
        4.repeat:
          if control & (1 << it) != 0:
            base-offset += delta-data[offset++] << 8 * it
        3.repeat:
          if control & (0b1_0000 << it) != 0:
            size += delta-data[offset++] << 8 * it
        buffer.write base-data[base-offset..base-offset+size]

    return buffer.bytes

  static build-tree objects/Map entry-hash/ByteArray -> any:
      object := objects.get entry-hash
      if not object: return {:} // Missing hash references, would be to dnagling commits in cloned/detached submodules. Interpret is empty dirs
      if object is List:
        node := Map
        object.do: | entry/TreeEntry_ |
          node[entry.name] = build-tree objects entry.hash
        return node
      else if object is ByteArray:
        return object
      else:
        throw "Unknown type: $object"

  static hash-entry type/string size/int data/ByteArray -> ByteArray:
    s := sha1.Sha1
    s.add type
    s.add " $size\0"
    s.add data
    return s.get


class TreeEntry_:
  hash/ByteArray
  name/string
  permission/string

  constructor .permission .name .hash:

  // https://stackoverflow.com/questions/14790681/what-is-the-internal-format-of-a-git-tree-object:
  //  (?<tree>  tree (?&SP) (?&decimal) \0 (?&entry)+ )
  //  (?<entry> (?&octal) (?&SP) (?&strnull) (?&sha1bytes) )
  //
  //  (?<strnull>   [^\0]+ \0)
  //  (?<sha1bytes> (?s: .{20}))
  //  (?<decimal>   [0-9]+)
  //  (?<octal>     [0-7]+)
  //  (?<SP>        \x20)
  // Except in the pack file, the preample  (?<tree>  tree (?&SP) (?&decimal) \0 is not nescessary and thus removed
  static parse b/ByteArray -> List:
    i := 0
    parsed := []

    while i < b.size:
      start := i
      while b[i] != ' ': i++
      perm := b[start..i].to-string
      i++
      start = i
      while b[i] != 0: i++
      n := b[start..i].to-string
      i++
      parsed.add (TreeEntry_ perm n b[i..i+20])
      i += 20
    return parsed

  stringify:
    return "$(%-6s permission) $(%-22s name) $(hex.encode hash)"

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

