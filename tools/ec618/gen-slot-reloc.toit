// Copyright (C) 2026 Toit contributors.

// Build the EC618 dual-slot relocation table from the canonical neutral-base
// link (the slot-A build artifact).
//
// The Toit firmware is a single position-independent image that the device
// localizes to whichever slot it writes (relocate-on-write). Slot A and slot
// B are 0x60000 apart, so the two images differ ONLY in:
//
//   1. ABS32 data pointers that point INTO the slot (vtables, const pointer
//      tables, .init_array, the .vm_entry word, ...). They move with the
//      slot, so the device adds `delta = dest_base - link_base` to each.
//   2. The Thumb BL/B.W branches that escape the slot to a fixed PLAT
//      address. Their source moves but their target is
//      fixed, so the device subtracts `delta` from the branch immediate.
//      The ones that straddle a 4 KB flash sector go to the SRL3 straddle
//      stream with their canonical bytes (see encode-table).
//
// Everything else is already slot-independent: within-slot BL/B.W branches
// (source and target move together) and movw/movt loads of fixed PLAT
// addresses.
//
// This tool reads the retained input relocations from `toit.elf` (linked with
// `-Wl,--emit-relocs`), classifies them, and emits a compact delta-encoded
// table. When given a slot-B link (`--verify-slot-b`) it PROVES the table is
// complete and correct: it relocates the slot-A image to slot B and asserts
// the result is byte-identical to the independent slot-B link. That check is
// the guard against `--emit-relocs` dropping a relocation.

import cli
import io show Buffer LITTLE-ENDIAN
import host.file
import host.pipe

import .partitions

// Reloc-table artifact magic: "SRL3" (Slot ReLoc, version 3 — v2 added the
// sector-straddle branch stream with embedded canonical bytes; v3 adds the
// BASE ID the slot was linked against, so the device can reject a slot
// built for a different base instead of faulting).
MAGIC ::= #['S', 'R', 'L', '3']

// The device writes (and erases) the slot in 4 KB flash sectors; a 2-aligned
// Thumb-branch site at `sector_end - 2` straddles two of them. Mirrors
// FLASH_SECTOR_SIZE in src/primitive_ec618.cc.
FLASH-SECTOR-SIZE ::= 0x1000

// Structural slot-boundary symbols denote FIXED flash addresses (the slot
// reservation geometry the dual-slot dispatcher reads), not moving image
// content. A reference to one is numerically inside the slot yet must NOT be
// relocated, so it is excluded from the ABS32 set.
FIXED-SLOT-SYMBOLS ::= {
  "__vm_a_start", "__vm_a_end",
  "__vm_b_start", "__vm_b_end",
  // The link-domain markers are FIXED addresses too: the VM references
  // __vm_link_base to recover the (build-time) link base at runtime, and it must
  // read the same value in EVERY slot. __vm_link_base == the link base, so its
  // value falls inside [link-base, hi) and would otherwise be (wrongly)
  // relocated like an in-slot pointer.
  "__vm_link_base", "__vm_link_end",
}

// Relocations storing a 32-bit absolute address. Relocated when the stored
// pointer lands inside the slot.
ABS32-TYPES ::= {"R_ARM_ABS32", "R_ARM_TARGET1"}

// PC-relative Thumb/ARM branch relocations. Relocated ONLY when the branch
// escapes the slot to a fixed target; within-slot branches are unchanged
// because the source and the target move by the same delta.
BRANCH-TYPES ::= {
  "R_ARM_THM_CALL", "R_ARM_CALL",
  "R_ARM_THM_JUMP24", "R_ARM_JUMP24",
  "R_ARM_THM_PC22",
}

// movw/movt absolute-address loads. The VM build uses `-mslow-flash-data`, so
// some addresses materialize via movw/movt; every current one targets a FIXED
// address (identical in both slots), so none need relocation. An in-slot
// target would require device-side movw/movt re-encoding (unimplemented) —
// the tool fails loudly.
MOVW-MOVT-TYPES ::= {
  "R_ARM_THM_MOVW_ABS_NC", "R_ARM_THM_MOVT_ABS",
  "R_ARM_MOVW_ABS_NC", "R_ARM_MOVT_ABS",
}

/** One relocation record parsed from `readelf -r`. */
class Reloc:
  offset/int       // The virtual address the relocation patches.
  type/string      // The R_ARM_* relocation type.
  sym-value/int    // The target symbol's resolved address.
  sym-name/string  // The target symbol's name (may be truncated/empty).

  constructor .offset .type .sym-value .sym-name:

main args:
  cmd := cli.Command "gen-slot-reloc"
      --help="""
        Extracts the EC618 dual-slot relocation table from the canonical
        neutral-base link (stored as the slot-A artifact and built with
        -Wl,--emit-relocs) and writes it to --out.

        With --verify-slot-b it proves the table by relocating the canonical
        image to slot B and asserting byte-identity with the slot-B oracle.
        """
      --options=[
        cli.Option "readelf"
            --help="The arm readelf binary."
            --default="arm-none-eabi-readelf",
        cli.Option "nm"
            --help="The arm nm binary."
            --default="arm-none-eabi-nm",
        cli.Option "ap-load-addr"
            --help="XIP address of ap.bin byte 0 (hex or decimal; default: the base XIP address from the partition descriptor).",
        partitions-option,
        cli.Option "elf"
            --help="The canonical neutral-base toit.elf (the slot-A artifact, linked with --emit-relocs)."
            --required,
        cli.Option "ap"
            --help="The slot-A ap.bin (flat binary)."
            --required,
        cli.Option "base"
            --help="The stamped base image (build/ec618-base/base.bin) whose base-id the table carries."
            --required,
        cli.Option "out"
            --help="The output reloc-table artifact path."
            --required,
        cli.Option "data-out"
            --help="Output path for the extracted VM .data init image (the per-slot data region, slot-data.bin)."
            --required,
        cli.Option "verify-slot-b"
            --help="A slot-B ap.bin to byte-identity-check against.",
      ]
      --run=:: run it
  cmd.run args

run invocation/cli.Invocation -> none:
  readelf := invocation["readelf"]
  nm := invocation["nm"]
  elf := invocation["elf"]
  ap-path := invocation["ap"]
  out-path := invocation["out"]
  data-out-path := invocation["data-out"]
  verify-path := invocation["verify-slot-b"]
  parts := Partitions.load invocation["partitions"]
  ap-load-addr := invocation["ap-load-addr"]
      ? parse-int invocation["ap-load-addr"]
      : parts.xip "base"

  // The image is LINKED at the neutral __vm_link_base (the canonical VMA, NEITHER
  // slot) and lives in the flash at slot A's address __vm_a_start (the LMA). The
  // two differ, so a relocation's virtual address (its slot-relative offset) maps
  // to a DIFFERENT file offset within ap.bin. The device adds
  // `delta = dest_slot_base - link_base` to each ABS32 word; with link_base != a
  // slot that is non-zero for BOTH slots, so slot A relocates too.
  syms := slot-symbols nm elf
  link-base := syms.get "__vm_link_base"
  link-end := syms.get "__vm_link_end"
  slot-a-flash := syms.get "__vm_a_start"
  slot-b-flash := syms.get "__vm_b_start"
  if link-base == null or link-end == null or slot-a-flash == null or slot-b-flash == null:
    pipe.print-to-stderr "missing __vm_link_base/__vm_link_end/__vm_a_start/__vm_b_start in $elf"
    exit 1
  if link-base == link-end:
    pipe.print-to-stderr "VM body is empty — expected the canonical slot-A artifact"
    exit 1
  slot-size := slot-b-flash - slot-a-flash
  body-size := link-end - link-base
  hi := link-base + slot-size  // Link-domain upper bound for "points into the slot".
  // Maps a relocation's virtual address to its file offset within ap.bin
  // (slot-relative offset + slot A's flash file offset).
  slot-a-file := slot-a-flash - ap-load-addr

  ap-a := file.read-contents ap-path

  // The base-id record the slot was linked against (see gen-base-id.toit).
  base-bin := file.read-contents invocation["base"]
  id-off := (parts.xip "base-id") - ap-load-addr
  if not (base-bin.size > id-off + 24 and base-bin[id-off] == 'T' and base-bin[id-off + 1] == 'B'
      and base-bin[id-off + 2] == 'I' and base-bin[id-off + 3] == '1'):
    pipe.print-to-stderr "no base-id record in $invocation["base"] — run gen-base-id first"
    exit 1
  base-version := LITTLE-ENDIAN.uint32 base-bin (id-off + 4)
  base-fp := base-bin.copy (id-off + 8) (id-off + 24)
  relocs := read-relocs readelf elf ".rel.vm_a"
  if relocs.is-empty:
    pipe.print-to-stderr "no .rel.vm_a relocations in $elf (was it linked with -Wl,--emit-relocs?)"
    exit 1

  abs32 := []  // Slot-relative offsets of ABS32 words to add `delta` to.
  thmbl := []  // Slot-relative offsets of escaping branches to re-encode.
  relocs.do: | r/Reloc |
    rel-off := r.offset - link-base
    if ABS32-TYPES.contains r.type:
      word := LITTLE-ENDIAN.uint32 ap-a (slot-a-file + rel-off)
      if link-base <= word and word < hi and not FIXED-SLOT-SYMBOLS.contains r.sym-name:
        abs32.add rel-off
    else if BRANCH-TYPES.contains r.type:
      if not (link-base <= r.sym-value and r.sym-value < hi):
        thmbl.add rel-off
    else if MOVW-MOVT-TYPES.contains r.type:
      if link-base <= r.sym-value and r.sym-value < hi and not FIXED-SLOT-SYMBOLS.contains r.sym-name:
        throw "unsupported in-slot movw/movt at 0x$(%x r.offset) -> $r.sym-name; extend gen-slot-reloc + the device relocator"
    else:
      throw "unknown relocation type $r.type at 0x$(%x r.offset) -> $r.sym-name"
  abs32.sort --in-place
  thmbl.sort --in-place

  // Branch sites that straddle a 4 KB sector boundary go to the straddle
  // stream, carrying their 4 CANONICAL bytes so the device's sector-chunked
  // relocate-on-write can patch them without seeing the neighbouring chunk.
  straddle := []  // Elements: [slot-relative offset, 4 canonical site bytes].
  plain-thmbl := []
  thmbl.do: | offset/int |
    if offset % FLASH-SECTOR-SIZE == FLASH-SECTOR-SIZE - 2:
      site := ap-a.copy (slot-a-file + offset) (slot-a-file + offset + 4)
      straddle.add [offset, site]
    else:
      plain-thmbl.add offset

  // Extract the VM's writable-.data init image (the per-slot data region). It is
  // bracketed in .load_dram_shared by __vm_data_start/_end (VMA); its bytes live
  // in ap.bin at the section's LOAD base plus the same in-section offset. The
  // image holds link-base slot pointers, carried per-slot, copied to RAM at
  // boot, then fixed up by relocate_data_slot_pointers.
  vm-data-start := syms.get "__vm_data_start"
  vm-data-end := syms.get "__vm_data_end"
  dram-vma := syms.get "Image\$\$VM_DRAM_DATA\$\$Base"
  dram-lma := syms.get "Load\$\$VM_DRAM_DATA\$\$Base"
  if vm-data-start == null or vm-data-end == null or dram-vma == null or dram-lma == null:
    pipe.print-to-stderr "missing __vm_data_start/_end or .vm_dram_data load/image base in $elf (linker .data bracket present?)"
    exit 1
  data-size := vm-data-end - vm-data-start
  if data-size < 0 or (data-size & 3) != 0:
    pipe.print-to-stderr "VM .data range [0x$(%x vm-data-start), 0x$(%x vm-data-end)) is empty or not word-aligned"
    exit 1
  vm-data-lma := dram-lma + (vm-data-start - dram-vma)
  vm-data-file := vm-data-lma - ap-load-addr
  if vm-data-file < 0 or vm-data-file + data-size > ap-a.size:
    pipe.print-to-stderr "VM .data init [ap file 0x$(%x vm-data-file), +0x$(%x data-size)) exceeds ap.bin ($ap-a.size bytes)"
    exit 1
  vm-data := ap-a.copy vm-data-file (vm-data-file + data-size)
  file.write-contents --path=data-out-path vm-data

  table := encode-table
      --base-version=base-version
      --base-fp=base-fp
      --link-base=link-base
      --slot-size=slot-size
      --body-size=body-size
      --data-size=data-size
      --abs32=abs32
      --thmbl=plain-thmbl
      --straddle=straddle
  file.write-contents --path=out-path table

  print "Slot reloc table: $abs32.size ABS32 + $plain-thmbl.size branch + $straddle.size sector-straddle reloc(s), $table.size bytes."
  print "  link-base=0x$(%x link-base) slot-a=0x$(%x slot-a-flash) slot-b=0x$(%x slot-b-flash) slot-size=0x$(%x slot-size) body=0x$(%x body-size)"
  print "  delta(A)=0x$(%x ((slot-a-flash - link-base) & 0xffffffff)) delta(B)=0x$(%x ((slot-b-flash - link-base) & 0xffffffff))"
  print "  VM .data init: 0x$(%x data-size) bytes @ ap file 0x$(%x vm-data-file) -> $data-out-path"
  print "  -> $out-path"

  if verify-path:
    ap-b := file.read-contents verify-path
    ok := verify
        --ap-a=ap-a
        --ap-b=ap-b
        --slot-a-file=slot-a-file
        --slot-b-file=(slot-b-flash - ap-load-addr)
        --body-size=body-size
        --abs32=abs32
        --thmbl=thmbl
        --delta=(slot-b-flash - link-base)
    if not ok:
      pipe.print-to-stderr "Byte-identity FAILED: the relocation table is incomplete or wrong."
      exit 1
    print "Byte-identity OK: canonical body relocated to slot B == slot-B link ($verify-path)."

/**
Reads the relocation records of $section from `$readelf -r $elf`.

Returns a list of $Reloc. Only data lines (whose type starts with `R_ARM`) are
  kept, so the column header and blank lines are skipped automatically.
*/
read-relocs readelf/string elf/string section/string -> List:
  relocs := []
  // `-W` (wide) avoids truncating the relocation type column
  // (e.g. R_ARM_THM_MOVW_ABS_NC would otherwise become R_ARM_THM_MOVW_AB).
  out := pipe.backticks [readelf, "-r", "-W", elf]
  in-section := false
  out.split "\n": | line/string |
    if line.starts-with "Relocation section":
      in-section = line.contains "'$section'"
      continue.split
    if not in-section: continue.split
    parts := split-whitespace line
    if parts.size < 4: continue.split
    type := parts[2]
    if not type.starts-with "R_ARM": continue.split
    offset := int.parse parts[0] --radix=16
    sym-value := int.parse parts[3] --radix=16
    sym-name := parts.size > 4 ? parts[4] : ""
    relocs.add (Reloc offset type sym-value sym-name)
  return relocs

// Symbols read from the link: the slot/link geometry, plus the VM .data bracket
// (__vm_data_start/_end) and the .vm_dram_data section's VMA/LMA bases, used
// to extract the VM's writable-.data init image from ap.bin.
WANTED-SYMBOLS ::= {
  "__vm_a_start", "__vm_a_end", "__vm_b_start", "__vm_b_end",
  "__vm_link_base", "__vm_link_end",
  "__vm_data_start", "__vm_data_end",
  "Load\$\$VM_DRAM_DATA\$\$Base", "Image\$\$VM_DRAM_DATA\$\$Base",
}

/** Reads the wanted symbol addresses (see $WANTED-SYMBOLS) from `$nm $elf`. */
slot-symbols nm/string elf/string -> Map:
  result := {:}
  out := pipe.backticks [nm, elf]
  out.split "\n": | line/string |
    parts := split-whitespace line
    if parts.size < 3: continue.split
    name := parts.last
    if WANTED-SYMBOLS.contains name:
      result[name] = int.parse parts[0] --radix=16
  return result

/**
Encodes the reloc-table artifact.

The header is `MAGIC` followed by $link-base, $slot-size, $body-size, the
  three counts and $data-size (all little-endian uint32). The $abs32 and
  $thmbl offset lists (slot-relative, ascending) follow as delta-encoded
  unsigned LEB128 varints; the $straddle stream follows as a delta-varint
  offset plus the site's 4 canonical bytes per entry (elements of $straddle
  are `[offset, site-bytes]` pairs, ascending). $data-size is the verbatim VM
  .data init image that rides after the body (0 when no .data region is
  carried). Mirrors `SlotRelocTable.to-bytes` in tools/ec618/slot-reloc.toit
  and `slot_reloc_parse` in src/slot_reloc_ec618.cc.
*/
encode-table --base-version/int --base-fp/ByteArray --link-base/int --slot-size/int --body-size/int --data-size/int --abs32/List --thmbl/List --straddle/List -> ByteArray:
  buffer := Buffer
  buffer.write MAGIC
  le := buffer.little-endian
  le.write-uint32 link-base
  le.write-uint32 slot-size
  le.write-uint32 body-size
  le.write-uint32 abs32.size
  le.write-uint32 thmbl.size
  le.write-uint32 data-size
  le.write-uint32 straddle.size
  le.write-uint32 base-version
  buffer.write base-fp
  write-varint-deltas buffer abs32
  write-varint-deltas buffer thmbl
  previous := 0
  straddle.do: | entry/List |
    offset/int := entry[0]
    write-varint buffer (offset - previous)
    previous = offset
    buffer.write entry[1]
  return buffer.bytes

/** Writes the ascending $offsets as delta-encoded unsigned LEB128 varints. */
write-varint-deltas buffer/Buffer offsets/List -> none:
  previous := 0
  offsets.do: | offset/int |
    write-varint buffer (offset - previous)
    previous = offset

/** Writes $value to $buffer as an unsigned LEB128 varint. */
write-varint buffer/Buffer value/int -> none:
  while true:
    b := value & 0x7f
    value >>= 7
    if value != 0:
      buffer.write-byte (b | 0x80)
    else:
      buffer.write-byte b
      return

/**
Relocates the slot content of $bytes in place by $delta.

$base is the file offset of the slot's first byte within $bytes; the $abs32 and
  $thmbl offsets are slot-relative. Each ABS32 word gains $delta; each escaping
  branch immediate loses $delta (its source moved by $delta but its fixed
  target did not).
*/
apply-reloc bytes/ByteArray base/int abs32/List thmbl/List delta/int -> none:
  abs32.do: | offset/int |
    p := base + offset
    word := LITTLE-ENDIAN.uint32 bytes p
    LITTLE-ENDIAN.put-uint32 bytes p ((word + delta) & 0xffffffff)
  thmbl.do: | offset/int |
    p := base + offset
    imm := thumb-branch-imm bytes p
    put-thumb-branch-imm bytes p (imm - delta)

/**
Relocates the slot-A image to slot B and checks byte-identity with $ap-b.

Returns whether the relocated slot-A content equals the slot-B link's content
  over $body-size bytes. Reports the first mismatch to stderr on failure.
*/
verify --ap-a/ByteArray --ap-b/ByteArray --slot-a-file/int --slot-b-file/int \
    --body-size/int --abs32/List --thmbl/List --delta/int -> bool:
  region := ap-a.copy slot-a-file (slot-a-file + body-size)
  apply-reloc region 0 abs32 thmbl delta
  body-size.repeat: | i/int |
    if region[i] != ap-b[slot-b-file + i]:
      pipe.print-to-stderr "  first mismatch at slot offset 0x$(%x i): relocated=0x$(%x region[i]) slot-B=0x$(%x ap-b[slot-b-file + i])"
      return false
  return true

/**
Decodes the signed branch immediate of a Thumb-2 BL/B.W at $offset in $bytes.

The 4-byte instruction is two little-endian halfwords. The immediate is the
  PC-relative offset (relative to the instruction address + 4).
*/
thumb-branch-imm bytes/ByteArray offset/int -> int:
  lo := LITTLE-ENDIAN.uint16 bytes offset
  hi := LITTLE-ENDIAN.uint16 bytes (offset + 2)
  s := (lo >> 10) & 1
  imm10 := lo & 0x3ff
  j1 := (hi >> 13) & 1
  j2 := (hi >> 11) & 1
  imm11 := hi & 0x7ff
  i1 := (j1 ^ s) ^ 1  // NOT(J1 XOR S).
  i2 := (j2 ^ s) ^ 1  // NOT(J2 XOR S).
  imm := (s << 24) | (i1 << 23) | (i2 << 22) | (imm10 << 12) | (imm11 << 1)
  // Sign-extend the 25-bit value.
  if (imm & 0x01000000) != 0: imm -= 0x02000000
  return imm

/**
Writes a Thumb-2 BL/B.W at $offset in $bytes with signed branch immediate $imm.

Preserves the opcode bits (BL vs B.W), so a re-encoded branch keeps its kind.
*/
put-thumb-branch-imm bytes/ByteArray offset/int imm/int -> none:
  imm &= 0x01ffffff
  s := (imm >> 24) & 1
  i1 := (imm >> 23) & 1
  i2 := (imm >> 22) & 1
  imm10 := (imm >> 12) & 0x3ff
  imm11 := (imm >> 1) & 0x7ff
  j1 := (i1 ^ 1) ^ s  // NOT(I1) XOR S.
  j2 := (i2 ^ 1) ^ s  // NOT(I2) XOR S.
  lo-old := LITTLE-ENDIAN.uint16 bytes offset
  hi-old := LITTLE-ENDIAN.uint16 bytes (offset + 2)
  lo := (lo-old & 0xf800) | (s << 10) | imm10
  hi := (hi-old & 0xd000) | (j1 << 13) | (j2 << 11) | imm11
  LITTLE-ENDIAN.put-uint16 bytes offset lo
  LITTLE-ENDIAN.put-uint16 bytes (offset + 2) hi

/** Parses an integer that may be hex (`0x`-prefixed) or decimal. */
parse-int s/string -> int:
  if s.starts-with "0x" or s.starts-with "0X":
    return int.parse s[2..] --radix=16
  return int.parse s

/** Splits a string on runs of whitespace, dropping empty tokens. */
split-whitespace str/string -> List:
  result := []
  current := []
  str.do: | c/int |
    if c == ' ' or c == '\t':
      if not current.is-empty:
        result.add (string.from-runes current)
        current = []
    else:
      current.add c
  if not current.is-empty:
    result.add (string.from-runes current)
  return result
