// Copyright (C) 2026 Toit contributors.
//
// Red-team round 2 crafting tool.
//
// Patches a compiled format-2 snapshot bundle in place: it locates the
// bytecode blob (the `TBC3` stream that both V2MethodTable::compute and the
// verified core read) inside the "snapshot" ar member and overwrites bytes
// at caller-chosen bytecode indices (bci). Because every patch preserves the
// blob length, the surrounding snapshot serialization and ar headers stay
// valid, so no re-encoding is needed.
//
// The bci of a method's header, its arity and body size come from
// `toit.run tools/spec_dump.toit <snap> <dump>` (the `m <id> <size> <arity>
// <name>` lines; id == header bci). The bytecode body starts right after the
// header. Edit operands, opcodes, method-header fields, etc. by bci.
//
// After patching run with inference so the verifier re-checks the edited
// program:  toit.run --untrusted --no-certificate out.snapshot
// (a shipped certificate would be checked against the OLD bytecodes). To test
// the shipped-certificate path instead, keep the certificate and drop
// --no-certificate.
//
// Usage:
//   craft info  <in>
//   craft patch <in> <out> [<bci> <hex> ]...
//     e.g. craft patch a.snap b.snap 226 0e 230 41ff
//   craft dump-blob <in> <out-bin>        // write just the TBC3 blob
//   craft set-byte  <in> <out> <abs-file-offset> <hex>   // raw file patch

import host.file

TBC3 ::= #[0x54, 0x42, 0x43, 0x33]  // Format 3 (TBC2 when this round ran).

// --- Minimal ar (Unix archive) support ------------------------------------

class ArMember:
  name/string
  data/ByteArray
  constructor .name .data:

ar-parse_ bytes/ByteArray -> List:
  if bytes.size < 8 or bytes[0] != '!': throw "not an ar archive"
  members := []
  pos := 8  // "!<arch>\n"
  while pos + 60 <= bytes.size:
    name := (bytes[pos .. pos + 16].to-string-non-throwing).trim
    if name.ends-with "/": name = name[0 .. name.size - 1]
    size-str := (bytes[pos + 48 .. pos + 58].to-string-non-throwing).trim
    size := int.parse size-str
    dstart := pos + 60
    members.add (ArMember name bytes[dstart .. dstart + size].copy)
    pos = dstart + size
    if size % 2 == 1: pos += 1  // padding
  return members

ar-write_ members/List -> ByteArray:
  parts := []
  parts.add "!<arch>\n".to-byte-array
  members.do: | m/ArMember |
    hdr := ByteArray 60
    hdr.replace 0 (ByteArray 60: ' ')  // fill with spaces
    name-field := m.name
    (name-field.size).repeat: hdr[it] = name-field[it]
    size-field := "$m.data.size"
    (size-field.size).repeat: hdr[48 + it] = size-field[it]
    hdr[58] = '`'
    hdr[59] = '\n'
    // mtime/uid/gid/mode left as spaces, like the producer's zeros-as-space.
    parts.add hdr
    parts.add m.data
    if m.data.size % 2 == 1: parts.add #['\n']
  total := 0
  parts.do: total += it.size
  out := ByteArray total
  o := 0
  parts.do: | p | out.replace o p; o += p.size
  return out

find-blob_ bytes/ByteArray -> int:
  // Find the single TBC3 occurrence (the bytecode blob start).
  found := -1
  for i := 0; i + 4 <= bytes.size; i++:
    if bytes[i] == 0x54 and bytes[i+1] == 0x42 and bytes[i+2] == 0x43 and bytes[i+3] == 0x32:
      if found >= 0: throw "multiple TBC3 markers; cannot disambiguate blob"
      found = i
  if found < 0: throw "no TBC3 marker: not a format-2 snapshot?"
  return found

blob-length_ bytes/ByteArray blob-offset/int -> int:
  // read-list-uint8_ stores an int32 little-endian length just before the
  // bytes.
  o := blob-offset - 4
  return bytes[o] | (bytes[o+1] << 8) | (bytes[o+2] << 16) | (bytes[o+3] << 24)

parse-hex_ s/string -> ByteArray:
  if s.size % 2 != 0: throw "odd hex length: $s"
  n := s.size / 2
  out := ByteArray n
  for i := 0; i < n; i++:
    out[i] = int.parse s[i*2 .. i*2+2] --radix=16
  return out

main args/List:
  if args.is-empty:
    print "usage: craft info|patch|dump-blob|set-byte ..."
    return
  cmd := args[0]
  if cmd == "info":
    bytes := file.read-contents args[1]
    off := find-blob_ bytes
    len := blob-length_ bytes off
    print "file-size=$bytes.size  blob-file-offset=$off  blob-length=$len"
    return
  if cmd == "dump-blob":
    bytes := file.read-contents args[1]
    off := find-blob_ bytes
    len := blob-length_ bytes off
    file.write-contents --path=args[3] bytes[off .. off + len]
    print "wrote $len bytes"
    return
  if cmd == "set-byte":
    bytes := file.read-contents args[1].copy
    bytes = bytes.copy
    patch := parse-hex_ args[4]
    o := int.parse args[3]
    patch.size.repeat: bytes[o + it] = patch[it]
    file.write-contents --path=args[2] bytes
    print "patched $patch.size byte(s) at file offset $o"
    return
  if cmd == "strip-cert":
    bytes := file.read-contents args[1]
    members := ar-parse_ bytes
    kept := members.filter: it.name != "certificate"
    file.write-contents --path=args[2] (ar-write_ kept)
    print "members: $(members.map: it.name) -> dropped certificate"
    return
  // patch [--keep-cert] <in> <out> [<bci> <hex>]...
  // Patches the snapshot member's TBC3 blob in place and (by default) drops
  // the now-stale certificate so the verifier infers a fresh one.
  if cmd == "patch":
    keep-cert := false
    a := 1
    if args[a] == "--keep-cert":
      keep-cert = true
      a += 1
    in := args[a]; out := args[a + 1]; a += 2
    bytes := file.read-contents in
    members := ar-parse_ bytes
    snap/ArMember? := null
    members.do: if it.name == "snapshot": snap = it
    if snap == null: throw "no snapshot member"
    blob := snap.data
    off := find-blob_ blob
    len := blob-length_ blob off
    count := 0
    while a + 1 < args.size:
      bci := int.parse args[a]
      patch := parse-hex_ args[a + 1]
      if bci < 0 or bci + patch.size > len: throw "patch at bci $bci out of range (blob len $len)"
      patch.size.repeat: blob[off + bci + it] = patch[it]
      count += patch.size
      a += 2
    kept := keep-cert ? members : (members.filter: it.name != "certificate")
    file.write-contents --path=out (ar-write_ kept)
    print "patched $count byte(s); blob at $off len $len; cert $(keep-cert ? "kept" : "dropped")"
    return
  print "unknown command: $cmd"
