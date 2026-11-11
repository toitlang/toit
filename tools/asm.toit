// Copyright (C) 2026 Toit contributors.
//
// Red-team round 3 METHOD ASSEMBLER (deliverable 2).
//
// Replaces the whole body of a chosen method in a format-2 snapshot with a
// symbolic instruction sequence (mnemonics from BYTE-CODES-V2, labels for
// branches). Rebuilds the method header length, splices the TBC2 blob, and
// fixes the blob length prefix, the segment content-size and the program
// header's off-heap byte count. Format-2 calls use method *indices*, so no
// other method needs relocating.
//
// Usage (run with --project-root tools):
//   asm list  <snap>                       # list methods (id/name/arity/size)
//   asm dump  <snap> <method-name>         # disassemble a method's body
//   asm patch <snap> <out> <method-name> <asm>
//     <asm> is ';'-separated: "MNEMONIC op...", labels "name:", branch ops take
//     a label.  Operands: decimal, 0xHEX, or a label (for branch targets).
//   Certificate is always dropped so the host re-infers/verifies.

import host.file
import io show LITTLE-ENDIAN
import .snapshot

TBC2 ::= #[0x54, 0x42, 0x43, 0x32]

opcode-of name/string -> int:
  BYTE-CODES-V2.size.repeat: | i | if BYTE-CODES-V2[i].name == name: return i
  throw "unknown mnemonic: $name"

bc-of name/string -> Bytecode:
  return BYTE-CODES-V2[opcode-of name]

// operand layout: list of {bytes, kind} where kind is "u"=unsigned immediate,
// "bf"=1-byte forward branch, "sf"=2-byte forward branch, "sb"=2-byte backward
// branch.  Derived from the instruction size and format.
operand-plan bc/Bytecode -> List:
  f := bc.format
  total := bc.size - 1   // operand bytes
  if f == OP: return []
  if f == OP-SF: return [[2, "sf"]]
  if f == OP-SB: return [[2, "sb"]]
  if f == OP-BF: return [[1, "bf"]]
  if f == OP-BU-WR: return [[1, "u"], [4, "u"]]     // non-local branch: height + (frames,target)
  if f == OP-BU-SU: return [[1, "u"], [2, "u"]]     // primitive: module + index
  if f == OP-BS-SO: return [[1, "u"], [2, "u"]]
  if f == OP-SS-SO: return [[2, "u"], [2, "u"]]
  if f == OP-SB-SB: return [[2, "u"], [2, "u"]]
  if f == OP-SU-SU: return [[2, "u"], [2, "u"]]
  if f == OP-WU: return [[4, "u"]]
  // all remaining single-operand formats: one immediate of (total) bytes
  return [[total, "u"]]

class Instr:
  mnemonic/string
  opcode/int := -1
  bc/Bytecode? := null
  ops/List           // raw operand tokens (strings)
  bci/int := 0
  raw/ByteArray? := null   // for the RAW pseudo-op
  constructor .mnemonic .ops:
    if mnemonic == "RAW":
      hex := ops[0]
      raw = ByteArray (hex.size / 2): int.parse hex[it*2..it*2+2] --radix=16
    else:
      opcode = opcode-of mnemonic
      bc = BYTE-CODES-V2[opcode]
  size -> int: return raw != null ? raw.size : bc.size

parse-token t/string labels/Map -> int:
  if labels.contains t: return labels[t]
  if t.starts-with "0x": return int.parse t[2..] --radix=16
  return int.parse t

assemble asm/string -> ByteArray:
  // Pass 0: tokenize into instrs and labels.
  instrs := []
  labels := {:}
  asm.split ";": | line |
    line = line.trim
    if line == "": continue.split
    if line.ends-with ":":
      labels[line[..(line.size - 1)]] = null   // placeholder, fixed in pass 1
      continue.split
    parts := (line.split " ").filter: it != ""
    instrs.add (Instr parts[0] parts[1..])
  // Pass 1: assign bcis and resolve label positions (labels attach to the NEXT
  // instruction). Re-walk tracking pending labels.
  instrs2 := []
  pending := []
  bci := 0
  asm.split ";": | line |
    line = line.trim
    if line == "": continue.split
    if line.ends-with ":":
      pending.add line[..(line.size - 1)]
      continue.split
    parts := (line.split " ").filter: it != ""
    ins := Instr parts[0] parts[1..]
    ins.bci = bci
    pending.do: labels[it] = bci
    pending = []
    instrs2.add ins
    bci += ins.size
  end-bci := bci
  pending.do: labels[it] = end-bci
  // Pass 2: emit.
  out := []
  instrs2.do: | ins/Instr |
    if ins.raw != null:
      ins.raw.do: out.add it
      continue.do
    out.add ins.opcode
    plan := operand-plan ins.bc
    oi := 0
    plan.do: | spec |
      width := spec[0]; kind := spec[1]
      val/int := ?
      if kind == "sf":
        target := parse-token ins.ops[oi] labels
        val = target - ins.bci
        oi++
      else if kind == "bf":
        target := parse-token ins.ops[oi] labels
        val = target - ins.bci
        oi++
      else if kind == "sb":
        target := parse-token ins.ops[oi] labels
        val = ins.bci - target
        oi++
      else:
        val = parse-token ins.ops[oi] labels
        oi++
      width.repeat: out.add (val >> (8 * it)) & 0xff
  return ByteArray out.size: out[it]

leb-encode v/int -> ByteArray:
  tmp := []
  while v >= 0x80:
    tmp.add (0x80 | (v & 0x7f))
    v >>= 7
  tmp.add v
  return ByteArray tmp.size: tmp[it]

leb-end bytes/ByteArray at/int -> int:
  p := at
  while bytes[p] & 0x80 != 0: p++
  return p + 1

find-method program/Program name/string -> ToitMethod:
  program.methods.do: | m/ToitMethod |
    info := program.method-info-for m.id (: null)
    if info and info.name == name: return m
  throw "method not found: $name"

main args/List:
  if args.is-empty:
    print "usage: asm list|dump|patch ..."
    return
  cmd := args[0]
  bundle := SnapshotBundle.from-file args[1]
  program := bundle.decode
  if cmd == "list":
    program.methods.do: | m/ToitMethod |
      info := program.method-info-for m.id (: null)
      nm := info ? info.name : "?"
      print "  id=$m.id kind=$m.kind arity=$m.arity hdr=$m.header-size body=$m.bytecodes.size  $nm"
    return
  if cmd == "dump":
    m := find-method program args[2]
    print "method $args[2]: id=$m.id arity=$m.arity kind=$m.kind header-size=$m.header-size body=$m.bytecodes.size"
    bci := 0
    while bci < m.bytecodes.size:
      op := m.bytecodes[bci]
      bc := BYTE-CODES-V2[op]
      print "  $(%3d bci): [$op] $bc.name ($bc.size)"
      bci += bc.size
    return
  if cmd == "patch":
    out := args[2]
    mname := args[3]
    asm := args[4]
    m := find-method program mname
    body := assemble asm
    // Build new header: [arity][flags] + LEB(new-body-len) + original trailing
    // header bytes (selector/receiver/aux), copied verbatim.
    all := program.all-bytecodes
    hdr-start := m.id
    arity-byte := all[hdr-start]
    flags-byte := all[hdr-start + 1]
    old-len-end := leb-end all (hdr-start + 2)
    trailing := all[old-len-end .. hdr-start + m.header-size]
    new-hdr := #[arity-byte, flags-byte] + (leb-encode body.size) + trailing
    new-method := new-hdr + body
    old-method-size := m.header-size + m.bytecodes.size
    new-blob := all[0 .. hdr-start] + new-method + all[hdr-start + old-method-size ..]
    // Splice into the raw snapshot bundle.
    bytes := file.read-contents args[1]
    // ar parse (manual).
    members := ar-parse bytes
    snap/ArMember? := null
    members.do: if it.name == "snapshot": snap = it
    seg := snap.data
    // locate TBC2 blob and its int32 length prefix.
    off := find-tbc2 seg
    old-blob-len := LITTLE-ENDIAN.int32 seg (off - 4)
    // new segment = seg[0..off-4] + int32(new-blob-len) + new-blob + seg[off+old-blob-len..]
    pre := seg[0 .. off - 4]
    post := seg[off + old-blob-len ..]
    lenbuf := ByteArray 4: (new-blob.size >> (8 * it)) & 0xff
    new-seg := pre + lenbuf + new-blob + post
    // fix segment content-size (bytes [4..8)).
    sz := new-seg.size
    4.repeat: new-seg[4 + it] = (sz >> (8 * it)) & 0xff
    // fix off-heap byte count (program header: 4th uint32 after the 8-byte seg
    // header => bytes [8+12 .. 8+16) = [20..24)). external_byte_count(64) =
    // round_up(blob-len, 8).
    ebc := (new-blob.size + 7) & ~7
    4.repeat: new-seg[20 + it] = (ebc >> (8 * it)) & 0xff
    snap.data = new-seg
    kept := members.filter: it.name != "certificate"
    file.write-contents --path=out (ar-write kept)
    print "patched method $mname: body $m.bytecodes.size -> $body.size bytes; blob $old-blob-len -> $new-blob.size; cert dropped"
    return
  print "unknown command: $cmd"

// ---- minimal ar (manual, compatible with producer) ----
class ArMember:
  name/string
  data/ByteArray := ?
  constructor .name .data:

ar-parse bytes/ByteArray -> List:
  members := []
  pos := 8
  while pos + 60 <= bytes.size:
    name := (bytes[pos .. pos + 16].to-string-non-throwing).trim
    if name.ends-with "/": name = name[0 .. name.size - 1]
    size := int.parse (bytes[pos + 48 .. pos + 58].to-string-non-throwing).trim
    dstart := pos + 60
    members.add (ArMember name bytes[dstart .. dstart + size].copy)
    pos = dstart + size
    if size % 2 == 1: pos += 1
  return members

ar-write members/List -> ByteArray:
  parts := []
  parts.add "!<arch>\n".to-byte-array
  members.do: | m/ArMember |
    hdr := ByteArray 60: ' '
    m.name.size.repeat: hdr[it] = m.name[it]
    sf := "$m.data.size"
    sf.size.repeat: hdr[48 + it] = sf[it]
    hdr[58] = '`'; hdr[59] = '\n'
    parts.add hdr; parts.add m.data
    if m.data.size % 2 == 1: parts.add #['\n']
  total := 0
  parts.do: total += it.size
  out := ByteArray total
  o := 0
  parts.do: | p | out.replace o p; o += p.size
  return out

find-tbc2 bytes/ByteArray -> int:
  found := -1
  i := 0
  while i + 4 <= bytes.size:
    if bytes[i] == 0x54 and bytes[i+1] == 0x42 and bytes[i+2] == 0x43 and bytes[i+3] == 0x32:
      if found >= 0: throw "multiple TBC2"
      found = i
    i++
  if found < 0: throw "no TBC2"
  return found
