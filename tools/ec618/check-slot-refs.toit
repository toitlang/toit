// Copyright (C) 2026 Toit contributors.

// Fixed-region -> slot reference guard for the EC618 dual-slot VM image.
//
// WHY: the dual-slot OTA relocates the VM image on write, and a handful of
// regions hold pointers INTO the slot that must move with it:
//
//   * the slot body itself (.vm_a)       -> relocated by the SRL1 table
//                                           (tools/ec618/gen-slot-reloc.toit),
//   * the shared writable .data          -> relocated at boot by
//     (.load_dram_shared/.load_dram_bsp)    relocate_data_slot_pointers()
//                                           (tools/ec618/gen-data-reloc.toit).
//
// EVERY OTHER allocated region is FIXED: PLAT loads it once at its link address
// and the device never relocates it. So a word in a fixed region that points
// INTO the slot is a latent fault: with the neutral link base it resolves to an
// unmapped VMA (0x01xxxxxx), and even at a slot-base link it would pin the image
// to one slot. This is exactly the invisible "B->A only" class of bug the
// relocation design fights — but on the FIXED side, where no relocation can
// rescue it.
//
// check-slot-pic.toit guards the slot->outside direction (every VM->PLAT call
// must go through an in-slot jump-table stub). This tool guards the inverse:
// it reads the linker's retained relocations (--emit-relocs) and FAILS if any
// allocated, non-relocated section has a relocation whose target resolves into
// the slot. The only sanctioned exceptions are in the allow-set.

import cli
import host.pipe

// Sections the device DOES relocate, so a pointer into the slot is expected and
// handled. Every other allocated section is fixed and must not reference the slot.
RELOCATED-SECTIONS ::= {".vm_a", ".load_dram_shared", ".load_dram_bsp"}

// Sanctioned fixed-region -> slot references (by target symbol name).
//
// `_ZnwjRKSt9nothrow_t` is `operator new(unsigned int, std::nothrow_t const&)`,
// defined in the slot (the VM's allocator). The C++ runtime's PLAT-resident
// `__cxa_thread_atexit` (libstdc++) calls it to allocate a thread-local-dtor
// node. That path is dead on this target (the VM registers no thread_local with
// a non-trivial destructor, so __cxa_thread_atexit is never invoked); it is
// allow-listed rather than relocated because PLAT cannot be relocated. If the VM
// ever uses such a thread_local this edge goes live and faults — eliminate it
// then (e.g. a VM-side __cxa_thread_atexit stub) rather than widening this set.
DEFAULT-ALLOW ::= {"_ZnwjRKSt9nothrow_t"}

main args:
  cmd := cli.Command "check-slot-refs"
      --help="""
        Fails if any allocated, non-relocated section of toit.elf (linked with
        -Wl,--emit-relocs) holds a relocation whose target resolves INTO the VM
        slot. Such a word is fixed at link time but the device never relocates
        it, so it points at the wrong (or an unmapped) address after OTA.

        The slot body (.vm_a) and the relocated shared .data are skipped — those
        ARE relocated. Targets in the allow-set are tolerated.
        """
      --options=[
        cli.Option "readelf"
            --help="The arm readelf binary."
            --default="arm-none-eabi-readelf",
        cli.Option "nm"
            --help="The arm nm binary."
            --default="arm-none-eabi-nm",
        cli.Option "allow"
            --help="Extra target symbol allowed as a fixed->slot reference (repeatable)."
            --multi,
      ]
      --rest=[
        cli.Option "elf"
            --help="The linked toit.elf to check (built with --emit-relocs)."
            --required,
      ]
      --run=:: run it
  cmd.run args

run invocation/cli.Invocation -> none:
  readelf := invocation["readelf"]
  nm := invocation["nm"]
  elf := invocation["elf"]
  allow := {}
  allow.add-all DEFAULT-ALLOW
  allow.add-all invocation["allow"]

  range := slot-range nm elf
  lo := range[0]
  hi := range[1]
  if lo == hi:
    pipe.print-to-stderr "no populated VM slot found (both __vm_link and __vm_b are empty)"
    exit 1

  alloc := alloc-sections readelf elf
  violations := find-references readelf elf lo hi alloc allow

  if not violations.is-empty:
    // Aggregate by "section -> symbol" for a compact report.
    counts := {:}
    violations.do: | key/string |
      counts[key] = (counts.get key --if-absent=: 0) + 1
    pipe.print-to-stderr "FAIL: $violations.size fixed-region word(s) reference the VM slot:"
    keys := []
    keys.add-all counts.keys
    keys.sort --in-place
    keys.do: | key/string |
      pipe.print-to-stderr "  $counts[key]x  $key"
    pipe.print-to-stderr """

      A fixed (non-relocated) section points INTO the slot. The device never
      relocates these words, so they resolve to the wrong (unmapped, with the
      neutral link base) address after OTA. Move the referenced object into the
      slot, route the call through the jump table, or — if the edge is provably
      dead — add the target symbol to check-slot-refs.toit's allow-set."""
    exit 1

  print "OK: no fixed-region word references the VM slot."

/**
Returns the populated VM slot range as a two-element list `[lo, hi]`.

Prefers `__vm_link_base`/`__vm_link_end` (the link-domain VMA the slot-A image's
  code lives at); falls back to `__vm_b_start`/`__vm_b_end` (the slot-B oracle
  link). Reads hex addresses from `$nm $elf`. Mirrors check-slot-pic.toit.
*/
slot-range nm/string elf/string -> List:
  symbols := {:}
  out := pipe.backticks [nm, elf]
  out.split "\n": | line/string |
    parts := split-whitespace line
    if parts.size < 2: continue.split
    name := parts.last
    if name == "__vm_link_base" or name == "__vm_link_end" \
        or name == "__vm_b_start" or name == "__vm_b_end":
      symbols[name] = int.parse parts[0] --radix=16

  a-start := symbols.get "__vm_link_base"
  a-end := symbols.get "__vm_link_end"
  if a-start != null and a-end != null and a-start != a-end:
    return [a-start, a-end]

  b-start := symbols.get "__vm_b_start"
  b-end := symbols.get "__vm_b_end"
  if b-start != null and b-end != null:
    return [b-start, b-end]

  if a-start != null and a-end != null:
    return [a-start, a-end]
  return [0, 0]

/** Returns the set of ALLOC section names (flags contain `A`) from `readelf -SW`. */
alloc-sections readelf/string elf/string -> Set:
  result := {}
  out := pipe.backticks [readelf, "-SW", elf]
  out.split "\n": | line/string |
    // A section line is "  [NN] .name TYPE addr off size es flg lk inf al".
    bracket := line.index-of "]"
    if bracket < 0: continue.split
    parts := split-whitespace line[bracket + 1..]
    // Need name, type, and the flags column. PROGBITS/NOBITS lines have the
    // flags after size/es; locate them by the section TYPE token.
    if parts.size < 6: continue.split
    name := parts[0]
    if not name.starts-with ".": continue.split
    // Flags are an UPPERCASE letter run; find the first all-flags token after
    // the numeric addr/off/size/es columns (index >= 5).
    for i := 5; i < parts.size; i++:
      if is-flags-token parts[i]:
        if (parts[i].contains "A"): result.add name
        break
  return result

/** Whether $token is an ELF section-flags token (letters like `WAX`, `AL`, `WA`). */
is-flags-token token/string -> bool:
  if token.is-empty: return false
  token.do: | c/int |
    if not ('A' <= c and c <= 'Z'): return false
  return true

/**
Returns the fixed-region -> slot references in $elf as a list of
  "section -> symbol" strings (one per offending relocation, duplicates kept).

A reference offends when the patched section is allocated (in $alloc) but NOT a
  relocated section ($RELOCATED-SECTIONS), the relocation's target value lands in
  `[$lo, $hi)`, and the target symbol is not in $allow.
*/
find-references readelf/string elf/string lo/int hi/int alloc/Set allow/Set -> List:
  references := []
  out := pipe.backticks [readelf, "-rW", elf]
  current/string? := null  // The allocated section the current `.rel.*` patches.
  skip := true             // Skip records until inside an interesting section.
  out.split "\n": | line/string |
    if line.starts-with "Relocation section":
      current = relocation-target-section line
      skip = current == null
          or RELOCATED-SECTIONS.contains current
          or not (alloc.contains current)
      continue.split
    if skip: continue.split
    parts := split-whitespace line
    if parts.size < 4: continue.split
    if not parts[2].starts-with "R_ARM": continue.split
    sym-value := int.parse parts[3] --radix=16 --if-error=: continue.split
    if not (lo <= sym-value and sym-value < hi): continue.split
    sym-name := parts.size > 4 ? parts[4] : "(section)"
    if allow.contains sym-name: continue.split
    references.add "$current -> $sym-name"
  return references

/**
Returns the section a `.rel.<section>`/`.rela.<section>` patches from a `readelf`
  "Relocation section '...'" header $line, or null.
*/
relocation-target-section line/string -> string?:
  start := line.index-of "'"
  if start < 0: return null
  end := line.index-of "'" (start + 1)
  if end < 0: return null
  name := line[start + 1 .. end]
  if name.starts-with ".rela": return name[5..]
  if name.starts-with ".rel": return name[4..]
  return name

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
