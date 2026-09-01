// Copyright (C) 2026 Toit contributors.

// Generate (or verify) the VM shared-.data slot-pointer relocation table.
//
// Each slot carries its own VM .data init, linked at the neutral link base.
// The per-slot SRL3 relocation (gen-slot-reloc.toit) only touches flash, never
// the shared RAM into which that init image is copied. Therefore every word in
// .data that holds a VM-slot pointer — the interpreter's computed-goto
// dispatch_table and the per-module `*_primitives_` tables — still points at
// the neutral link base after the copy.
//
// This tool reads the linker's own `.rel.load_dram_* -> .vm_a` records (the
// SAME ground truth `--emit-relocs` produces for the slot table) and emits a C
// array of the RAM addresses of those words. toit_ec618.cc's
// relocate_data_slot_pointers() adds the slot displacement to each at boot.
//
// By default the tool writes the build-directory C source. `--check`
// re-extracts from the final ELF and asserts that source still matches, which
// is the fixed-point guard against the generated table moving its own targets.

import cli
import host.file
import host.pipe

import .elf

TOOL-NAME ::= "tools/ec618/gen-data-reloc.toit"

// The writable RAM .data PROGBITS sections that hold the shared VM globals.
// With the reserved .vm_dram_data section, the VM's
// writable globals — the only legitimate home of shared-RAM slot pointers —
// live there exclusively. A slot pointer in any OTHER dram section is a bug
// that check-slot-refs reports.
DATA-SECTIONS ::= {".vm_dram_data"}

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
            --help="The generated C source path to emit or check."
            --required,
        cli.Flag "check"
            --help="Verify --out matches the elf instead of writing it."
            --default=false,
      ]
      --run=:: run it
  cmd.run args

run invocation/cli.Invocation -> none:
  ui := invocation.cli.ui
  readelf := invocation["readelf"]
  elf := invocation["elf"]
  out-path := invocation["out"]
  check := invocation["check"]

  addresses := extract-addresses --readelf=readelf --elf=elf
  if addresses.is-empty:
    ui.abort "no .data -> .vm_a relocations found in $elf"

  source := render-source addresses

  if check:
    existing/string? := null
    catch: existing = (file.read-contents out-path).to-string
    if existing != source:
      ui.abort """
        $out-path is STALE ($addresses.size .data slot pointers in $elf).
        The generated table changed its own layout. Re-run the provisional
        link/generate/final-link sequence."""
    print "gen-data-reloc: $out-path matches the elf ($addresses.size pointers)."
    return

  file.write-contents --path=out-path source
  print "gen-data-reloc: wrote $addresses.size .data slot-pointer addresses -> $out-path"

/**
Returns the sorted RAM addresses of the writable-.data words that hold a
  pointer into the VM slot (`.vm_a`).

Parses `readelf -rW`: in `.rel.vm_dram_data`, every `R_ARM_ABS32`
  whose target symbol resolves into `.vm_a` is such a word. For a linked
  EXECUTABLE the relocation Offset is already the absolute virtual (RAM)
  address, so it is used directly.

The parsed header and record lines look like:

```
Relocation section '.rel.vm_dram_data' at offset 0xa0c888 contains 144 entries:
0043b900  00000102 R_ARM_ABS32  00d00000  .vm_a
```
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
    if not current or not (DATA-SECTIONS.contains current): continue.split
    parts := split-whitespace line
    if parts.size < 4: continue.split
    if parts[2] != "R_ARM_ABS32": continue.split
    // Keep only words that point INTO the VM slot (section symbol `.vm_a` or
    // any named symbol defined there): Sym.Value lands in `.vm_a`.
    sym-value := int.parse parts[3] --radix=16
    if not (vm-start <= sym-value < vm-end): continue.split
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
    // per-module *_primitives_ tables. Each slot's .data init is linked at the
    // neutral link base, so toit_ec618.cc shifts these words to the booted slot
    // before the VM starts.
    #include <stdint.h>

    const uint32_t toit_data_reloc_count = $addresses.size;
    const uint32_t toit_data_reloc[] = {
    $body
    };
    """
