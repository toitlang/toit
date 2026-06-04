// Copyright (C) 2026 Toit contributors.

// Position-independence guard for the EC618 dual-slot VM image.
//
// WHY: the dual-slot OTA scheme relocates the VM image on write, so slot-A
// and slot-B images must differ ONLY in their relocatable data pointers —
// never in code. For that to hold, every VM->PLAT call must go through the
// in-slot jump-table stub (`__wrap_<sym>` -> `g_plat_jt[slot]`), so the
// branch target stays inside the slot and the PLAT address is reached
// indirectly through the table. A direct `bl` to a PLAT address (outside the
// slot) would bake an absolute, slot-specific address into the code, so the
// two slot images would diverge in their code bytes and the relocate-on-write
// would corrupt one of them.
//
// This tool disassembles the populated VM slot and fails if any `bl`/`blx`/
// `b.w`/`b` branches to an address OUTSIDE the slot (an "escape"), unless the
// target symbol is in the allow-set. The only sanctioned escape is
// `__wrap_time`, whose target is itself a fixed-address shim.

import cli
import host.pipe

/**
The single allowed escape: `__wrap_time` is a manually wrapped, fixed-address
  shim, so a direct branch to it does not make the two slots diverge.
*/
DEFAULT-ALLOW ::= {"__wrap_time"}

/** Branch mnemonics whose target is checked for escapes. */
BRANCH-MNEMONICS ::= {"bl", "blx", "b.w", "b"}

main args:
  cmd := cli.Command "check-slot-pic"
      --help="""
        Verifies that the populated VM slot is position-independent: every
        VM->PLAT call must branch within the slot (through a jump-table stub),
        so slot-A and slot-B images differ only in relocatable data pointers.

        Exits non-zero (after printing the escapes) if any branch leaves the
        slot to a symbol that is not in the allow-set.
        """
      --options=[
        cli.Option "objdump"
            --help="The arm objdump binary."
            --default="arm-none-eabi-objdump",
        cli.Option "nm"
            --help="The arm nm binary."
            --default="arm-none-eabi-nm",
        cli.Option "allow"
            --help="Extra symbol allowed as a branch target (repeatable)."
            --multi,
      ]
      --rest=[
        cli.Option "elf"
            --help="The linked toit.elf to check."
            --required,
      ]
      --run=:: run it
  cmd.run args

run invocation/cli.Invocation -> none:
  objdump := invocation["objdump"]
  nm := invocation["nm"]
  elf := invocation["elf"]
  allow := {}
  extra-allow/List := invocation["allow"]
  if extra-allow.is-empty:
    allow.add-all DEFAULT-ALLOW
  else:
    allow.add-all extra-allow

  range := slot-range nm elf
  lo := range[0]
  hi := range[1]
  if lo == hi:
    pipe.print-to-stderr "no populated VM slot found (both __vm_a and __vm_b are empty)"
    exit 1

  escapes := find-escapes objdump elf lo hi allow

  if not escapes.is-empty:
    // Aggregate by symbol for a compact report.
    counts := {:}
    escapes.do: | name/string |
      counts[name] = (counts.get name --if-absent=: 0) + 1
    pipe.print-to-stderr "FAIL: $escapes.size VM->PLAT branch(es) escape the slot:"
    names := []
    names.add-all counts.keys
    names.sort --in-place
    names.do: | name/string |
      pipe.print-to-stderr "  $counts[name]x  $name"
    exit 1

  print "OK: no VM->PLAT branches escape the slot."

/**
Returns the populated VM slot range as a two-element list `[lo, hi]`.

Prefers the `__vm_link_base`/`__vm_link_end` symbols (the link-domain VMA the
  slot-A image's code actually lives at — NOT __vm_a_start, which is slot A's
  flash address with no code at it in the ELF); if that range is empty (start
  equals end), falls back to `__vm_b_start`/`__vm_b_end` (the slot-B oracle link,
  which is linked directly at slot B). Reads addresses (the 1st field, hex) from
  `$nm $elf`.
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

  // Nothing populated; signal an empty range so the caller can error.
  if a-start != null and a-end != null:
    return [a-start, a-end]
  return [0, 0]

/**
Disassembles the `[$lo, $hi)` range of $elf and returns the names of all
  branch targets that escape the slot.

A branch escapes when its mnemonic is in $BRANCH-MNEMONICS, its target address
  is outside `[$lo, $hi)`, and the target symbol is not in $allow. The returned
  list contains one entry per escaping branch (duplicates kept for counting).
*/
find-escapes objdump/string elf/string lo/int hi/int allow/Set -> List:
  escapes := []
  out := pipe.backticks [
    objdump,
    "-d",
    "--start-address=0x$(%x lo)",
    "--stop-address=0x$(%x hi)",
    elf,
  ]
  out.split "\n": | line/string |
    // Disassembly lines are TAB-separated:
    //   "<addr>:\t<bytes>\t<mnemonic>\t<target-addr> <name>".
    fields := line.split "\t"
    if fields.size < 4: continue.split
    mnemonic := fields[2]
    if not BRANCH-MNEMONICS.contains mnemonic: continue.split
    operand := fields[3]
    target := parse-branch-target operand
    if target == null: continue.split
    addr := target[0]
    name := target[1]
    if lo <= addr and addr < hi: continue.split
    if allow.contains name: continue.split
    escapes.add name
  return escapes

/**
Parses a branch operand `"<addr> <name>"` into `[addr, name]`, or null.

The address is the leading hex token; the name is taken from the `<...>`
  symbol reference with any trailing `+0x..` offset stripped.
*/
parse-branch-target operand/string -> List?:
  space := operand.index-of " "
  if space == -1: return null
  addr-token := operand[..space]
  rest := operand[space + 1..]
  if not rest.starts-with "<": return null
  close := rest.index-of ">"
  if close == -1: return null
  name := rest[1..close]
  // Strip a trailing `+0x..` offset (`<sym+0x4>`).
  plus := name.index-of "+"
  if plus >= 0: name = name[..plus]
  addr := int.parse addr-token --radix=16 --if-error=: return null
  return [addr, name]

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
