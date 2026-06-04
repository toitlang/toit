// Copyright (C) 2026 Toit contributors.

// Generate (or verify) the VM shared-.data slot-pointer relocation table.
//
// The VM's writable .data (.load_dram_shared) is loaded ONCE by PLAT from a
// fixed flash image — the link slot's (slot A's) data-init — and the per-slot
// SRL1 relocation (gen-slot-reloc.toit) only ever touches the VM slot itself,
// never this shared RAM. So every word in .data that holds a VM-slot pointer —
// the interpreter's computed-goto dispatch_table and the per-module
// `*_primitives_` tables — is baked at slot A. When the device boots a
// DIFFERENT slot those words point into slot A, so the interpreter would run
// slot A's code (and an OTA writing slot A would erase the code it executes).
//
// This tool reads the linker's own `.rel.load_dram_* -> .vm_a` records (the
// SAME ground truth `--emit-relocs` produces for the slot table) and emits a C
// array of the RAM addresses of those words. toit_ec618.cc's
// relocate_data_slot_pointers() adds the slot displacement to each at boot.
//
//   --emit   writes the C source (src/toit_data_reloc.c).
//   --check  re-extracts from the elf and asserts the committed C source still
//            matches — a guard against the .data layout drifting (regenerate
//            with --emit if it fails).

import cli
import host.file
import host.pipe

TOOL-NAME ::= "tools/ec618/gen-data-reloc.toit"

// The writable RAM .data PROGBITS sections that hold the shared VM globals.
DATA-SECTIONS ::= {".load_dram_shared", ".load_dram_bsp"}

// Structural slot-boundary symbols are FIXED flash addresses (slot geometry),
// not moving image content — a .data word holding one must NOT be relocated.
// Matches gen-slot-reloc.toit's FIXED-SLOT-SYMBOLS.
FIXED-SLOT-SYMBOLS ::= {"__vm_a_start", "__vm_a_end", "__vm_b_start", "__vm_b_end",
    // Link-domain markers are FIXED addresses too (see gen-slot-reloc.toit).
    "__vm_link_base", "__vm_link_end"}

main args:
  cmd := cli.Command "gen-data-reloc"
      --help="""
        Extracts the writable-.data words that hold VM-slot pointers from
        toit.elf's `.rel.load_dram_* -> .vm_a` records and emits (or verifies)
        the C table that relocate_data_slot_pointers() applies at boot.
        """
      --options=[
        cli.Option "readelf"
            --help="The arm readelf binary."
            --default="arm-none-eabi-readelf",
        cli.Option "elf"
            --help="The linked toit.elf (with --emit-relocs)."
            --required,
        cli.Option "out"
            --help="The C source path to emit / check (src/toit_data_reloc.c)."
            --required,
        cli.Flag "check"
            --help="Verify --out matches the elf instead of writing it."
            --default=false,
      ]
      --run=:: run it
  cmd.run args

run invocation/cli.Invocation -> none:
  readelf := invocation["readelf"]
  elf := invocation["elf"]
  out-path := invocation["out"]
  check := invocation["check"]

  addresses := extract-addresses --readelf=readelf --elf=elf
  if addresses.is-empty:
    pipe.print-to-stderr "no .data -> .vm_a relocations found in $elf"
    exit 1

  source := render-source addresses

  if check:
    existing/string? := null
    catch: existing = (file.read-contents out-path).to-string
    if existing != source:
      pipe.print-to-stderr """
        $out-path is STALE ($addresses.size .data slot pointers in $elf).
        The VM .data layout changed; regenerate with:
          $TOOL-NAME --elf=<toit.elf> --out=$out-path"""
      exit 1
    print "gen-data-reloc: $out-path matches the elf ($addresses.size pointers)."
    return

  file.write-contents --path=out-path source
  print "gen-data-reloc: wrote $addresses.size .data slot-pointer addresses -> $out-path"

/**
Returns the sorted RAM addresses of the writable-.data words that hold a
  pointer into the VM slot (`.vm_a`).

Parses `readelf -rW`: in each `.rel.load_dram_*` section, every `R_ARM_ABS32`
  whose target symbol resolves into `.vm_a` is such a word. For a linked
  EXECUTABLE the relocation Offset is already the absolute virtual (RAM)
  address, so it is used directly.
*/
extract-addresses --readelf/string --elf/string -> List:
  range := vm-a-range readelf elf
  vm-start := range[0]
  vm-end := range[1]
  addresses := {}
  out := pipe.backticks [readelf, "-rW", elf]
  current/string? := null  // The section the current `.rel.<section>` patches.
  out.split "\n": | line/string |
    if line.starts-with "Relocation section":
      // Line: `Relocation section '.rel.load_dram_shared' at offset ...`.
      current = relocation-target-section line
      continue.split
    if current == null or not (DATA-SECTIONS.contains current): continue.split
    parts := split-whitespace line
    if parts.size < 4: continue.split
    if parts[2] != "R_ARM_ABS32": continue.split
    // Keep only words that point INTO the VM slot (section symbol `.vm_a` or
    // any named symbol defined there): Sym.Value lands in `.vm_a`.
    sym-value := int.parse parts[3] --radix=16
    if not (vm-start <= sym-value and sym-value < vm-end): continue.split
    sym-name := parts.size > 4 ? parts[4] : ""
    if FIXED-SLOT-SYMBOLS.contains sym-name: continue.split
    addresses.add (int.parse parts[0] --radix=16)
  sorted := []
  sorted.add-all addresses
  sorted.sort --in-place
  return sorted

/** Returns `[start, end)` of the `.vm_a` section from `readelf -SW`. */
vm-a-range readelf/string elf/string -> List:
  out := pipe.backticks [readelf, "-SW", elf]
  out.split "\n": | line/string |
    parts := split-whitespace line
    idx := parts.index-of ".vm_a"
    // `[NN] .vm_a PROGBITS ADDR OFF SIZE ...` -> ADDR at idx+2, SIZE at idx+4.
    if idx >= 0 and idx + 4 < parts.size and parts[idx + 1] == "PROGBITS":
      addr := int.parse parts[idx + 2] --radix=16
      size := int.parse parts[idx + 4] --radix=16
      return [addr, addr + size]
  throw "no .vm_a section in $elf"

/**
Returns the section a `.rel.<section>` patches, from a `readelf` "Relocation
  section '...'" header $line — i.e. `.rel.load_dram_shared` -> `.load_dram_shared`.
*/
relocation-target-section line/string -> string?:
  start := line.index-of "'"
  if start < 0: return null
  end := line.index-of "'" (start + 1)
  if end < 0: return null
  name := line[start + 1 .. end]
  return name.starts-with ".rel" ? name[4..] : name

/** Emits the C source for the address table. */
render-source addresses/List -> string:
  lines := []
  for i := 0; i < addresses.size; i += 8:
    row := []
    for j := i; j < addresses.size and j < i + 8; j++:
      row.add "0x$(%08x addresses[j]),"
    lines.add "  $(row.join " ")"
  body := lines.join "\n"
  return """
    // Copyright (C) 2026 Toit contributors.
    //
    // AUTO-GENERATED by $TOOL-NAME — do not edit by hand.
    //
    // RAM addresses of writable .data words (.load_dram_shared) that hold
    // VM-slot pointers: the interpreter computed-goto dispatch_table and the
    // per-module *_primitives_ tables. This shared .data is loaded once from a
    // fixed flash image (the link slot's data-init), so on any other slot they
    // point into the wrong slot; toit_ec618.cc relocates them at boot (start()).
    #include <stdint.h>

    const uint32_t toit_data_reloc_count = $addresses.size;
    const uint32_t toit_data_reloc[] = {
    $body
    };
    """

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
