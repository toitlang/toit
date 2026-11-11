// Copyright (C) 2026 Toit contributors.
//
// Red-team round 3 METHOD ASSEMBLER (deliverable 2).
//
// Replaces the whole body of a chosen method in a format-2 snapshot with a
// symbolic instruction sequence (mnemonics from BYTE-CODES-V2, labels for
// branches). Splices the TBC2 blob, moves the entries of the following
// methods in the method table literal (format note 21; --stale-table leaves
// it inconsistent on purpose, an attack the loader must reject), and
// fixes the blob length prefix, the segment content-size and the program
// header's off-heap byte count. Format-2 calls use method *indices*, so no
// other method needs relocating.
//
// Usage (run with --project-root tools):
//   asm list  <snap>                       # list methods (id/name/arity/size)
//   asm dump  <snap> <method-name>         # disassemble a method's body
//   asm patch [--stale-table] <snap> <out> <method-name> <asm>
//     <asm> is ';'-separated: "MNEMONIC op...", labels "name:", branch ops take
//     a label.  Operands: decimal, 0xHEX, a label (for branch targets), or
//     @NAME, the dispatch-table index of the static method NAME.
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

/**
Moves the entries after $entry by $delta in the method table literal
  (format note 21: marker "TMT2", count, bytecodes length, 0, then records
  of the entry in the high 24 bits and the arity in the low 8), which the
  snapshot $seg holds verbatim (byte arrays above the snapshot's internal
  size cutoff), and sets its bytecodes length.
*/
patch-table seg/ByteArray entry/int delta/int bytecodes-size/int -> none:
  at := find-unique seg #['T', 'M', 'T', '2'] "TMT2"
  count := LITTLE-ENDIAN.uint32 seg (at + 4)
  if at + 16 + 4 * count > seg.size: throw "truncated method table literal"
  LITTLE-ENDIAN.put-uint32 seg (at + 8) bytecodes-size
  count.repeat: | i |
    p := at + 16 + 4 * i
    record := LITTLE-ENDIAN.uint32 seg p
    e := record >> 8
    if e > entry: LITTLE-ENDIAN.put-uint32 seg p (((e + delta) << 8) | (record & 0xff))

/**
Replaces every operand "@NAME" with the dispatch-table index of the
  (static) method NAME, so that a battery does not hard-code an index that
  changes with every compilation of the library.
*/
resolve-names program/Program asm/string -> string:
  result := ""
  i := 0
  while i < asm.size:
    if asm[i] != '@':
      result += asm[i..i + 1]
      i++
      continue
    end := i + 1
    while end < asm.size and asm[end] != ' ' and asm[end] != ';': end++
    name := asm[i + 1..end]
    m := find-method program name
    index := program.methods.index-of m
    d := program.dispatch-table.index-of index
    if d < 0: throw "no dispatch entry for $name"
    result += "$d"
    i = end
  return result

find-method program/Program name/string -> ToitMethod:
  program.methods.do: | m/ToitMethod |
    info := program.method-info-for m.id (: null)
    if info and info.name == name: return m
  throw "method not found: $name"

main args/List:
  if args.is-empty:
    print "usage: asm list|dump|patch ..."
    return
  // --stale-table (patch): leave the method table literal as it was (its
  //   records then point into other methods or past the bytecodes): an
  //   attack on the loader, which must reject it cleanly.
  stale-table := args.contains "--stale-table"
  args = args.filter: it != "--stale-table"
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
    body := assemble (resolve-names program asm)
    // The entries of all but blocks are odd (format note 21): a body that
    // changes by an odd number of bytes gets a pad byte at its end, so that
    // the following entries keep their parity. 0xff is no opcode: a body
    // that does not end in a terminator still runs into an invalid
    // instruction (the compiler pads with RETURN_NULL after a terminator).
    if (body.size - m.bytecodes.size) & 1 != 0: body += #[0xff]
    // Format note 21: the header ends at the entry and holds no body
    // length; the body ends at the next method's header. Replace the body
    // and move the entries of the following methods in the table literal.
    all := program.all-bytecodes
    entry := m.id + m.header-size
    old-body-size := m.bytecodes.size
    new-blob := all[0 .. entry] + body + all[entry + old-body-size ..]
    delta := body.size - old-body-size
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
    // Fix the off-heap byte count (program header: 4th uint32 after the
    // 8-byte segment header, bytes [20..24)). It covers every off-heap byte
    // (the bytecodes rounded to 8, and external byte arrays such as the
    // method table literal): move it by the change of the bytecodes' share
    // only. (Overwriting it with the bytecodes' size alone made every
    // patched snapshot fail to install, INVALID_ARGUMENT, once the table
    // literal existed.)
    ebc := LITTLE-ENDIAN.uint32 new-seg 20
    ebc += ((new-blob.size + 7) & ~7) - ((old-blob-len + 7) & ~7)
    LITTLE-ENDIAN.put-uint32 new-seg 20 ebc
    // --stale-table: the table's bytecodes length is fixed but its records
    // are not, so the loader's per-record checks must catch them.
    patch-table new-seg entry (stale-table ? 0 : delta) new-blob.size
    table-note := stale-table ? "table records stale" : "table moved by $delta"
    snap.data = new-seg
    kept := members.filter: it.name != "certificate"
    file.write-contents --path=out (ar-write kept)
    print "patched method $mname: body $m.bytecodes.size -> $body.size bytes; blob $old-blob-len -> $new-blob.size; $table-note; cert dropped"
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
  return find-unique bytes TBC2 "TBC2"

find-unique bytes/ByteArray pattern/ByteArray name/string -> int:
  found := -1
  i := 0
  while i + pattern.size <= bytes.size:
    if bytes[i] == pattern[0] and bytes[i .. i + pattern.size] == pattern:
      if found >= 0: throw "multiple $name"
      found = i
    i++
  if found < 0: throw "no $name"
  return found
