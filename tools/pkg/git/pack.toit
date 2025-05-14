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

import crypto.sha1
import encoding.hex
import host.file
import host.directory
import io
import io show BIG-ENDIAN
import zlib

import ..file-system-view
import .git

class Pack:
  version/int
  binary-data_/ByteArray
  content_ := {:}

  constructor .binary-data_ ref-hash/string:
    // See: git help format-pack.
    if "PACK" != binary-data_[0..4].to-string-non-throwing:
      throw "Invalid pack file"
    version = BIG-ENDIAN.uint32 binary-data_ 4
    if version > 2: throw "Unsuported pack version $version"

    content_ = parse-binary-data_ binary-data_ ref-hash

  /**
  Expands the pack file to the given location $path on disk.
  */
  expand path/string:
    expand_ path content_

  /**
  Saves the compressed pack file to the given location $path on disk.
  */
  save path/string:
    file.write-contents binary-data_ --path=path

  /**
  A file-system view of this pack.
  Returns the extracted data as a memory structure, where each entry in the map represents
    either a file or a directory. If the value is a $Map then the entry is a sub-directory and
    if the value is a $ByteArray, the entry is a file. In either case, the key is the name of
    the file/directory.
  */
  content -> FileSystemView: return GitFileSystemView content_

  static expand_ path m/Map:
    directory.mkdir --recursive path
    m.do: | name/string value/any |
      file-name := "$path/$name"
      if value is ByteArray:
        stats := file.stat file-name
        if not stats: // TODO: Implement overwrite, including a chmod in host.file.
          file.write-contents value --path="$path/$name"
      else:
        expand_ "$path/$name" value

  static TYPE-COMMIT_ ::= 1
  static TYPE-TREE_ ::= 2
  static TYPE-BLOB_ ::= 3
  static TYPE-TAG_ ::= 4
  static TYPE-OFS-DELTA_ ::= 6
  static TYPE-REF-DELTA_ ::= 7

  static parse-binary-data_ binary-data/ByteArray ref-hash/string -> Map:
    num-entries := BIG-ENDIAN.uint32 binary-data 8

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
          uncompress-size = header-byte & 0b1111
        else:
          uncompress-size |= (header-byte & 0b0111_1111) << header-shift
          header-shift += 7
        if header-byte& 0b1000_0000 == 0: break

      if entry-type == TYPE-COMMIT_ or entry-type == TYPE-TREE_ or
         entry-type == TYPE-BLOB_ or entry-type == TYPE-TAG_:
         // Undeltified representation.
        read := read-uncompressed_ uncompress-size binary-data[offset..]
        offset += read[0]
        entry-data := read[1]

        if entry-type == TYPE-COMMIT_:
          entry-hash := hash-entry "commit" uncompress-size entry-data
          if (hex.encode entry-hash) == ref-hash:
            top-tree = hex.decode entry-data[5..45].to-string

        if entry-type == TYPE-TREE_:
          entry-hash := hash-entry "tree" uncompress-size entry-data
          objects[entry-hash] = TreeEntry_.parse entry-data

        if entry-type == TYPE-BLOB_:
          entry-hash := hash-entry "blob" uncompress-size entry-data
          objects[entry-hash] = entry-data

        if entry-type == TYPE-TAG_:
          // Ignore.

      // deltified representation
      if entry-type == TYPE-OFS-DELTA_:
        throw "Unsurported delta type: ofs"

      if entry-type == TYPE-REF-DELTA_:
        base-hash := binary-data[offset..offset+20]
        offset = offset + 20
        read := read-uncompressed_ uncompress-size binary-data[offset..]
        offset += read[0]
        delta-data := read[1]

        blob := extract-refs_ objects[base-hash] delta-data
        entry-hash := hash-entry "blob" blob.size blob
        objects[entry-hash] = blob

    return build-tree objects top-tree

  static read-uncompressed_ uncompressed-size/int input/ByteArray -> List:
    decoder := zlib.Decoder
    try:
      buffer := io.Buffer
      written := 0

      while true:
        written += decoder.out.try-write input[written..]
        buffer.write (decoder.in.read --no-wait)
        if buffer.size >= uncompressed-size: break

      if buffer.size != uncompressed-size:
        throw "Invalid entry, expected $uncompressed-size bytes, but got $buffer.size"
      return [written, buffer.bytes]
    finally:
      decoder.out.close

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

    buffer := io.Buffer
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
      if not object:
        // Missing hash references, would be to dangling commits in cloned/detached submodules.
        // Interpret as empty dirs.
        return {:}
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
  // Except in the pack file, the preample  (?<tree>  tree (?&SP) (?&decimal) \0 is not nescessary and thus not included,
  // so the code just parses (?&entry)+
  static parse data/ByteArray -> List:
    i := 0
    parsed := []

    while i < data.size:
      start := i
      while data[i] != ' ': i++
      permissions := data[start..i].to-string
      i++
      start = i
      while data[i] != 0: i++
      name := data[start..i].to-string
      i++
      hash := data[i..i+20]
      parsed.add (TreeEntry_ permissions name hash)
      i += 20
    return parsed

  stringify:
    return "$(%-6s permission) $(%-22s name) $(hex.encode hash)"
