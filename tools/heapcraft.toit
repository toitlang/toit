// Copyright (C) 2026 Toit contributors.
//
// Red-team round 3 PROGRAM-HEAP EDITOR.
//
// Parses the "snapshot" ar member of a format-2 bundle, decodes the program
// segment's heap-object stream (global-variables, literals, roots, builtin
// class-ids) into an editable node tree that exactly reproduces the snapshot
// serialization (see src/snapshot.cc SnapshotReader / src/program.cc
// Program::write), lets the attacker mutate heap objects, and writes back a
// loadable snapshot.
//
// Correctness: `verify` re-emits with no edits and asserts byte-identity with
// the original segment, so the parser/emitter are a faithful round-trip.
//
// Allocation-preserving edits (changing a field's tagged value within the
// 32-bit smi range or to a reference, changing header/class-id bits, changing
// string/byte-array content of equal length) do not change block or off-heap
// counts, so only the segment content-size and the ar member size are
// recomputed; stream bytes may grow/shrink freely. Edits that change an
// object's allocation size (optlen/length/content-length) are "best effort":
// block counts are left as-is (the loader fails cleanly if a block overflows),
// and `verify-load` confirms the result still loads.
//
// Usage (run with --project-root tools):
//   heapcraft verify <in>
//   heapcraft list   <in>
//   heapcraft edit [--keep-cert] <in> <out> <op>...
// Ops (obj = flat object index from `list`):
//   field <obj> <fidx> smi:<n>        set instance field / array element to a smi
//   field <obj> <fidx> ref:<backidx>  ... to a back-reference to object with that table index
//   field <obj> <fidx> self           ... to a back-reference to <obj> itself (cycle)
//   header <obj> class:<id>           change class id, keep tag/finalizer
//   header <obj> raw:<value>          set the raw header smi value
//   optlen <obj> <n>                  set the object's optional-length (allocation length field)
//   fieldcount <obj> <n>              set an instance's separately-encoded field count
//   content <obj> <hex>               replace string/byte-array content bytes (any length)

import host.file
import .snapshot show Program SnapshotBundle

// ---------------- ar bundle helpers (compatible with the producer) --------

class ArMember:
  name/string
  data/ByteArray := ?
  constructor .name .data:

ar-parse_ bytes/ByteArray -> List:
  if bytes.size < 8 or bytes[0] != '!': throw "not an ar archive"
  members := []
  pos := 8
  while pos + 60 <= bytes.size:
    name := (bytes[pos .. pos + 16].to-string-non-throwing).trim
    if name.ends-with "/": name = name[0 .. name.size - 1]
    size-str := (bytes[pos + 48 .. pos + 58].to-string-non-throwing).trim
    size := int.parse size-str
    dstart := pos + 60
    members.add (ArMember name bytes[dstart .. dstart + size].copy)
    pos = dstart + size
    if size % 2 == 1: pos += 1
  return members

ar-write_ members/List -> ByteArray:
  parts := []
  parts.add "!<arch>\n".to-byte-array
  members.do: | m/ArMember |
    hdr := ByteArray 60: ' '
    name-field := m.name
    (name-field.size).repeat: hdr[it] = name-field[it]
    size-field := "$m.data.size"
    (size-field.size).repeat: hdr[48 + it] = size-field[it]
    hdr[58] = '`'
    hdr[59] = '\n'
    parts.add hdr
    parts.add m.data
    if m.data.size % 2 == 1: parts.add #['\n']
  total := 0
  parts.do: total += it.size
  out := ByteArray total
  o := 0
  parts.do: | p | out.replace o p; o += p.size
  return out

// ---------------- output buffer -------------------------------------------

class Buf:
  chunks_/List := []
  size_/int := 0
  byte b/int: chunks_.add (ByteArray 1: b); size_++
  bytes ba/ByteArray from/int=0 to/int=ba.size:
    slice := ba[from..to]
    chunks_.add slice
    size_ += slice.size
  cardinal v/int:
    tmp := []
    while v >= 128:
      tmp.add (128 | (v & 127))
      v >>= 7
    tmp.add v
    chunks_.add (ByteArray tmp.size: tmp[it])
    size_ += tmp.size
  int32 v/int:
    chunks_.add (ByteArray 4: (v >> (8 * it)) & 0xff)
    size_ += 4
  size -> int: return size_
  collect -> ByteArray:
    out := ByteArray size_
    o := 0
    chunks_.do: | c | out.replace o c; o += c.size
    return out

// ---------------- node model ----------------------------------------------

OBJECT-TAG ::= 0
IN-TABLE-TAG ::= 1
BACK-REFERENCE-TAG ::= 2
POSITIVE-SMI-TAG ::= 3
NEGATIVE-SMI-TAG ::= 4

TAG-ARRAY ::= 0
TAG-STRING ::= 1
TAG-INSTANCE ::= 2
TAG-ODDBALL ::= 3
TAG-FLOAT ::= 4
TAG-BYTEARRAY ::= 5

CUTOFF ::= (1024 * 4) >> 2   // SNAPSHOT-INTERNAL-SIZE-CUTOFF = 1024

abstract class Node:
  abstract emit buf/Buf -> none

class SmiNode extends Node:
  neg/bool
  mag/int
  constructor .neg .mag:
  emit buf/Buf -> none:
    buf.cardinal (neg ? NEGATIVE-SMI-TAG : POSITIVE-SMI-TAG)
    buf.cardinal mag
  value -> int: return neg ? -mag : mag

class RefNode extends Node:
  index/int
  constructor .index:
  emit buf/Buf -> none:
    buf.cardinal (BACK-REFERENCE-TAG + (index << 3))

class ObjNode extends Node:
  in-table/bool
  heap-tag/int
  optlen/int := ?
  header/SmiNode? := null
  // payload (only one used, by heap-tag)
  elems/List := []            // array
  fieldcount/int := 0         // instance
  fields/List := []           // instance
  str-external/bool := false
  str-bytes/ByteArray := #[]  // string internal content, or external [size bytes] incl. null
  ba-external/bool := false
  ba-vals/List := []          // bytearray internal cardinals
  ba-bytes/ByteArray := #[]   // bytearray external bytes
  float-bytes/ByteArray := #[]
  obj-index/int := -1         // flat index assigned at parse
  table-index/int := -1       // back-table index if in-table

  constructor .in-table .heap-tag .optlen:

  class-id -> int: return (header.value >> 5) & 0x3ff
  class-tag -> int: return header.value & 0xf
  finalizer -> int: return (header.value >> 4) & 1

  kind-name -> string:
    if heap-tag == TAG-ARRAY: return "array"
    if heap-tag == TAG-STRING: return "string"
    if heap-tag == TAG-INSTANCE: return "instance"
    if heap-tag == TAG-ODDBALL: return "oddball"
    if heap-tag == TAG-FLOAT: return "float"
    if heap-tag == TAG-BYTEARRAY: return "bytearray"
    return "?"

  emit buf/Buf -> none:
    buf.cardinal ((in-table ? IN-TABLE-TAG : OBJECT-TAG) + (optlen << 3))
    buf.byte heap-tag
    header.emit buf
    if heap-tag == TAG-ARRAY:
      elems.do: | e/Node | e.emit buf
    else if heap-tag == TAG-INSTANCE:
      buf.cardinal fieldcount
      fields.do: | f/Node | f.emit buf
    else if heap-tag == TAG-STRING:
      if str-external:
        buf.int32 str-bytes.size
        buf.bytes str-bytes
      else:
        buf.bytes str-bytes
    else if heap-tag == TAG-BYTEARRAY:
      if ba-external:
        buf.int32 ba-bytes.size
        buf.bytes ba-bytes
      else:
        ba-vals.do: | v/int | buf.cardinal v
    else if heap-tag == TAG-FLOAT:
      buf.bytes float-bytes
    // oddball: nothing

// ---------------- parser ---------------------------------------------------

class Reader:
  bytes/ByteArray
  pos/int := 0
  back-table/List := []   // ObjNode in table order
  all-objs/List := []     // flat list of ObjNode in parse order
  constructor .bytes .pos:

  byte -> int: return bytes[pos++]
  u32 -> int:
    r := bytes[pos] | (bytes[pos+1]<<8) | (bytes[pos+2]<<16) | (bytes[pos+3]<<24)
    pos += 4
    return r
  i32 -> int:
    r := u32
    if r >= 0x80000000: r -= 0x100000000
    return r
  cardinal -> int:
    result := 0
    shift := 0
    b := byte
    while b >= 128:
      result += (b - 128) << shift
      shift += 7
      b = byte
    result += b << shift
    return result

  read-object -> Node:
    header := cardinal
    type := header & 7
    extra := header >> 3
    if type == POSITIVE-SMI-TAG: return SmiNode false cardinal
    if type == NEGATIVE-SMI-TAG: return SmiNode true cardinal
    if type == BACK-REFERENCE-TAG: return RefNode extra
    // OBJECT-TAG or IN-TABLE-TAG
    in-table := type == IN-TABLE-TAG
    optlen := extra
    heap-tag := byte
    obj := ObjNode in-table heap-tag optlen
    obj.obj-index = all-objs.size
    all-objs.add obj
    if in-table:
      obj.table-index = back-table.size
      back-table.add obj
    // header is a nested read-object (a smi)
    h := read-object
    obj.header = h as SmiNode
    if heap-tag == TAG-ARRAY:
      obj.elems = List optlen: read-object
    else if heap-tag == TAG-INSTANCE:
      obj.fieldcount = cardinal
      obj.fields = List obj.fieldcount: read-object
    else if heap-tag == TAG-STRING:
      if optlen > CUTOFF:
        obj.str-external = true
        n := i32
        obj.str-bytes = bytes[pos..pos+n].copy
        pos += n
      else:
        obj.str-bytes = bytes[pos..pos+optlen].copy
        pos += optlen
    else if heap-tag == TAG-BYTEARRAY:
      if optlen > CUTOFF:
        obj.ba-external = true
        n := i32
        obj.ba-bytes = bytes[pos..pos+n].copy
        pos += n
      else:
        obj.ba-vals = List optlen: cardinal
    else if heap-tag == TAG-FLOAT:
      obj.float-bytes = bytes[pos..pos+8].copy
      pos += 8
    // oddball: nothing
    return obj

// ---------------- program segment ------------------------------------------

class Segment:
  member/ByteArray
  // verbatim prefix [0..gv-start), the 4 object lists, verbatim suffix.
  prefix-end/int := 0
  suffix-start/int := 0
  global-vars/List := []
  literals/List := []
  roots/List := []
  builtins/List := []
  reader/Reader
  constructor .member:
    reader = Reader member 0

  parse:
    r := reader
    r.pos = 8                 // segment header
    6.repeat: r.u32           // program header (block/offheap/table/large-int)
    clsbits-n := r.i32
    r.pos += 2 * clsbits-n    // class_bits uint16 list
    prefix-end = r.pos
    gv-n := r.cardinal
    global-vars = List gv-n: r.read-object
    lit-n := r.cardinal
    literals = List lit-n: r.read-object
    root-n := r.cardinal
    roots = List root-n: r.read-object
    bic-n := r.cardinal
    builtins = List bic-n: r.read-object
    suffix-start = r.pos

  emit -> ByteArray:
    buf := Buf
    buf.bytes member 0 prefix-end
    buf.cardinal global-vars.size
    global-vars.do: | n/Node | n.emit buf
    buf.cardinal literals.size
    literals.do: | n/Node | n.emit buf
    buf.cardinal roots.size
    roots.do: | n/Node | n.emit buf
    buf.cardinal builtins.size
    builtins.do: | n/Node | n.emit buf
    buf.bytes member suffix-start member.size
    seg := buf.collect
    // fix segment content-size (bytes [4..8) little-endian)
    sz := seg.size
    seg[4] = sz & 0xff
    seg[5] = (sz >> 8) & 0xff
    seg[6] = (sz >> 16) & 0xff
    seg[7] = (sz >> 24) & 0xff
    return seg

  obj idx/int -> ObjNode: return reader.all-objs[idx]

// ---------------- commands -------------------------------------------------

load-segment path/string -> List:
  // returns [members, snapshot-member, Segment]
  bytes := file.read-contents path
  members := ar-parse_ bytes
  snap/ArMember? := null
  members.do: if it.name == "snapshot": snap = it
  if snap == null: throw "no snapshot member"
  seg := Segment snap.data
  seg.parse
  return [members, snap, seg]

describe-node n/Node reader/Reader -> string:
  if n is SmiNode: return "smi=$((n as SmiNode).value)"
  if n is RefNode: return "ref->obj@table$((n as RefNode).index)"
  if n is ObjNode: return "obj#$((n as ObjNode).obj-index)"
  return "?"

cmd-list seg/Segment:
  print "objects: $seg.reader.all-objs.size  back-table: $seg.reader.back-table.size"
  print "lists: globals=$seg.global-vars.size literals=$seg.literals.size roots=$seg.roots.size builtins=$seg.builtins.size"
  seg.reader.all-objs.do: | o/ObjNode |
    ti := o.in-table ? "T$o.table-index" : "-"
    extra := ""
    if o.heap-tag == TAG-INSTANCE: extra = "fields=$o.fieldcount optlen=$o.optlen cid=$o.class-id"
    else if o.heap-tag == TAG-ARRAY: extra = "len=$o.optlen cid=$o.class-id"
    else if o.heap-tag == TAG-STRING: extra = "len=$o.optlen \"$(o.str-bytes.to-string-non-throwing)\""
    else if o.heap-tag == TAG-BYTEARRAY: extra = "len=$o.optlen"
    else if o.heap-tag == TAG-FLOAT: extra = "cid=$o.class-id"
    else: extra = "cid=$o.class-id"
    print "  #$o.obj-index [$ti] $o.kind-name tag=$o.class-tag $extra"
    if o.heap-tag == TAG-INSTANCE:
      o.fields.size.repeat: | f |
        print "       .$f = $(describe-node o.fields[f] seg.reader)"

/**
Prints, space separated, the answer to each query, so that a battery
  names objects and classes instead of hard-coding indices that change with
  every compilation of the library:
  str:TEXT        index of the first string object with that content
  ref-str:TEXT    its back-table index (for `ref:`)
  bytes:HEX       index of the first byte array with that content
  ref-inst:NAME   back-table index of the first instance of class NAME
  float           index of the first float
  cls:NAME        class id of the class NAME (from the source map)
  inst:NAME       index of the first instance (or oddball) of class NAME
  root:NAME       index of the first root of class NAME
  classes         the number of classes
*/
cmd-find path/string seg/Segment queries/List:
  program := Program (SnapshotBundle.from-file path)
  class-count := program.class-tags.size
  class-id := : | name/string |
    found := -1
    class-count.repeat: | id |
      if found < 0 and (program.class-info-for id: null) and (program.class-name-for id) == name: found = id
    if found < 0: throw "no class $name"
    found
  first := : | pred/Lambda what/string |
    found/ObjNode? := null
    seg.reader.all-objs.do: | o/ObjNode | if not found and (pred.call o): found = o
    if not found: throw "no $what"
    found
  root := : | cid/int name/string |
    found/ObjNode? := null
    seg.roots.do: | n | if not found and n is ObjNode and (n as ObjNode).class-id == cid: found = n
    if not found: throw "no root of class $name"
    found
  answers := queries.map: | q/string |
    if q.starts-with "str:":
      text := q[4..]
      (first.call (:: it.heap-tag == TAG-STRING and it.str-bytes.to-string-non-throwing == text) q).obj-index
    else if q.starts-with "ref-str:":
      text := q[8..]
      o := first.call (:: it.heap-tag == TAG-STRING and it.str-bytes.to-string-non-throwing == text) q
      if not o.in-table: throw "$q is not in the back-table"
      o.table-index
    else if q.starts-with "bytes:":
      want := hex-to-bytes q[6..]
      content := :: | o/ObjNode | o.ba-external ? o.ba-bytes : (ByteArray o.ba-vals.size: o.ba-vals[it])
      (first.call (:: it.heap-tag == TAG-BYTEARRAY and (content.call it) == want) q).obj-index
    else if q.starts-with "ref-inst:":
      cid := class-id.call q[9..]
      o := first.call (:: it.heap-tag != TAG-STRING and it.heap-tag != TAG-BYTEARRAY and it.class-id == cid) q
      if not o.in-table: throw "$q is not in the back-table"
      o.table-index
    else if q == "float":
      (first.call (:: it.heap-tag == TAG-FLOAT) q).obj-index
    else if q.starts-with "cls:":
      class-id.call q[4..]
    else if q.starts-with "inst:":
      cid := class-id.call q[5..]
      (first.call (:: it.heap-tag != TAG-STRING and it.heap-tag != TAG-BYTEARRAY and it.class-id == cid) q).obj-index
    else if q.starts-with "root:":
      (root.call (class-id.call q[5..]) q[5..]).obj-index
    else if q == "classes":
      class-count
    else:
      throw "bad query: $q"
  print (answers.join " ")

parse-spec spec/string owner/ObjNode -> Node:
  if spec.starts-with "smi:":
    v := int.parse spec[4..]
    return SmiNode (v < 0) (v < 0 ? -v : v)
  if spec.starts-with "ref:":
    return RefNode (int.parse spec[4..])
  if spec == "self":
    if owner.table-index < 0: throw "owner obj#$owner.obj-index is not in the back-table; cannot self-reference"
    return RefNode owner.table-index
  throw "bad spec: $spec"

hex-to-bytes s/string -> ByteArray:
  n := s.size / 2
  return ByteArray n: int.parse s[it*2..it*2+2] --radix=16

main args/List:
  if args.is-empty:
    print "usage: heapcraft verify|list|edit ..."
    return
  cmd := args[0]
  if cmd == "verify":
    r := load-segment args[1]
    seg/Segment := r[2]
    out := seg.emit
    orig := (r[1] as ArMember).data
    // compare ignoring the content-size bytes we rewrite (should match anyway)
    ok := out.size == orig.size
    if ok:
      out.size.repeat: if out[it] != orig[it]: ok = false
    if ok:
      print "ROUND-TRIP OK ($out.size bytes)"
    else:
      print "ROUND-TRIP MISMATCH (out=$out.size orig=$orig.size)"
      lim := min out.size orig.size
      i := 0
      while i < lim:
        if out[i] != orig[i]:
          print "  first diff at $i: out=$out[i] orig=$orig[i]"
          i = lim
        i++
    return
  if cmd == "list":
    r := load-segment args[1]
    cmd-list r[2]
    return
  if cmd == "find":
    r := load-segment args[1]
    cmd-find args[1] r[2] args[2..]
    return
  if cmd == "edit":
    a := 1
    keep-cert := false
    if args[a] == "--keep-cert": keep-cert = true; a++
    in := args[a]; out := args[a+1]; a += 2
    r := load-segment in
    members/List := r[0]
    seg/Segment := r[2]
    while a < args.size:
      op := args[a++]
      if op == "field":
        oi := int.parse args[a++]; fi := int.parse args[a++]; spec := args[a++]
        o := seg.obj oi
        node := parse-spec spec o
        if o.heap-tag == TAG-INSTANCE: o.fields[fi] = node
        else if o.heap-tag == TAG-ARRAY: o.elems[fi] = node
        else: throw "obj#$oi is not an instance/array"
      else if op == "header":
        oi := int.parse args[a++]; spec := args[a++]
        o := seg.obj oi
        if spec.starts-with "class:":
          cid := int.parse spec[6..]
          o.header = SmiNode false ((o.header.value & 0x1f) | (cid << 5))
        else if spec.starts-with "raw:":
          v := int.parse spec[4..]
          o.header = SmiNode false v
        else: throw "bad header spec"
      else if op == "optlen":
        oi := int.parse args[a++]; n := int.parse args[a++]
        (seg.obj oi).optlen = n
      else if op == "fieldcount":
        oi := int.parse args[a++]; n := int.parse args[a++]
        (seg.obj oi).fieldcount = n
      else if op == "content":
        oi := int.parse args[a++]; hex := args[a++]
        o := seg.obj oi
        b := hex-to-bytes hex
        if o.heap-tag == TAG-STRING: o.str-bytes = b
        else if o.heap-tag == TAG-BYTEARRAY: o.ba-vals = List b.size: b[it]
        else: throw "obj#$oi is not string/bytearray"
      else:
        throw "unknown op: $op"
    new-seg := seg.emit
    (r[1] as ArMember).data = new-seg
    kept := keep-cert ? members : (members.filter: it.name != "certificate")
    file.write-contents --path=out (ar-write_ kept)
    print "wrote $out ($new-seg.size byte segment); cert $(keep-cert ? "kept" : "dropped")"
    return
  print "unknown command: $cmd"
