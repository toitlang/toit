// Copyright (C) 2026 Toit contributors.

// Generate the PLAT jump table header + source from the set of symbols the
// VM calls into PLAT, plus the matching `-Wl,--wrap=<sym>` ldflags fragment,
// and patch the PLAT_JT_LDFLAGS block in xmake.lua.
//
// This consolidates the two Python helpers (extract_plat_jt_symbols.py +
// gen_plat_jt.py) into one tool. It first extracts the symbol set from the
// VM archives' object relocations, then emits all outputs.
//
// Extraction (robust to the dual-slot split and to existing --wrap flags):
//   1. Read the VM archives' object RELOCATIONS (R_ARM_*_CALL / JUMP24).
//      Relocations carry the *referenced* symbol name from the object — the
//      name the compiler emitted (e.g. `printf`, `__aeabi_dadd`), NOT the
//      link-time-resolved alias. Only the referenced name can be wrapped
//      with `-Wl,--wrap=`, so this is what we must list.
//   2. Drop targets the VM archives define themselves (intra-VM calls).
//   3. Drop an EXCLUDE set of references with no PLAT definition.
//   4. Drop mangled C++ references that resolve to nothing in the final elf.
//   5. Route the manually-wrapped libc time helpers through their `__wrap_*`
//      name (the manual `-Wl,--wrap=time` already rewrites `time`).
//
// The source pairs with `-Wl,--wrap=<sym>` flags in xmake.lua; the wrap
// mechanism rewrites each VM-side call into `__wrap_<sym>`, which the
// generated stub forwards through `g_plat_jt`.

import cli
import host.file
import host.pipe

TOOL-NAME ::= "tools/ec618/gen-plat-jt.toit"

// Manually wrapped (custom RTC-backed) libc helpers (see __wrap.c +
// xmake.lua): the VM's `time` is rewritten to `__wrap_time` by the manual
// `-Wl,--wrap=time`, so the jump table routes `__wrap_time`, not `time`.
MANUAL-WRAP ::= {"clock", "localtime", "gmtime", "time"}

// "Generous" jump table (the immutable-PLAT <-> OTA'able-VM ABI). The table
// is baked into fixed PLAT at flash time and FROZEN: a future VM OTA'd into a
// slot (no PLAT reflash) can only reach PLAT functions that ALREADY have an
// entry. So in addition to the relocation-derived set (what the CURRENT VM
// calls) we always include a curated hardware/system + libc/libm API surface,
// restricted to symbols PLAT already DEFINES (so no PLAT growth — only a 4 B
// table slot + a 16 B in-slot stub each, bounded by .jt_data = 4 KB ~ 1024).
// The cellular/USB/IP stack internals (Cerrc*/Asn*/Cemm*/usb*/tcp/...) are
// deliberately excluded — they are not API a future firmware would call.
//
// Prefix matches (peripheral / power / system / board control):
ALWAYS-INCLUDE-PREFIXES ::= [
  "BSP_",
  "Driver_", "ARM_",                                   // CMSIS driver interfaces.
  "GPIO", "gpio", "Pad", "pad", "PAD",                 // GPIO + pinmux.
  "I2C", "SPI", "UART", "USART", "ADC", "PWM",         // Peripheral drivers.
  "DMA", "TIMER", "Timer", "HAL_",
  "slpMan", "soc_", "PM_", "clk", "Clock", "clock", "CLOCK",  // Sleep / power / clock.
  "GPR", "pwr", "PWR", "Power", "power",
  "WDT", "wdt", "Wdt", "RTC", "rtc", "Rtc",            // Watchdog / RTC.
  "Flash", "flash", "QSPI", "qspi", "FDB", "fdb", "EF_",  // Flash / registry.
  "luat_",                                             // LuatOS convenience API.
  "__aeabi_",                                          // ARM EABI runtime (soft float / int helpers).
]

// Exact matches: libc/libm functions a future firmware is likely to call but
// the current VM may not (so they are absent from the relocation-derived set).
// Listed explicitly rather than by `mem`/`str` prefix to avoid pinning
// unrelated internal symbols.
ALWAYS-INCLUDE-EXACT ::= {
  // Hardware helpers outside the prefix surface: the efuse ADC-trim loader
  // (calibrated HAL_ADC_CalibrateRawCode path) and the busy-wait helper.
  "trimAdcSetGolbalVar", "delay_us",
  "memcpy", "memmove", "memset", "memcmp", "memchr",
  "strlen", "strcmp", "strncmp", "strcpy", "strncpy", "strcat", "strncat",
  "strchr", "strrchr", "strstr", "strtok", "strtol", "strtoul", "strtod",
  "strspn", "strcspn", "strpbrk", "strerror",
  "snprintf", "vsnprintf", "sprintf", "vsprintf", "sscanf", "vsscanf",
  "malloc", "free", "calloc", "realloc", "abs", "labs",
  "atoi", "atol", "atof", "qsort", "bsearch", "rand", "srand",
  "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
  "sinh", "cosh", "tanh", "exp", "exp2", "log", "log2", "log10",
  "pow", "sqrt", "cbrt", "ceil", "floor", "round", "trunc",
  "fabs", "fmod", "ldexp", "frexp", "modf", "hypot", "copysign", "fmin", "fmax",
}

// CMSIS driver ACCESS STRUCTS — data, not functions (they live in flash,
// so nm reports them as 'T' and the function filter doesn't catch them).
// They must NOT be in the table at all: routing their ADDRESS through a
// code veneer makes the VM read "function pointers" out of stub machine
// code — an instant fault (observed on I2C bring-up: &Driver_I2C0 resolved
// to the veneer). The VM binds to the fixed-PLAT structs directly, which
// is slot-safe.
DATA-SYMBOLS ::= {"Driver_I2C0", "Driver_I2C1", "Driver_USART0", "Driver_USART1"}

// PLAT functions the table must carry even though the CURRENT image does
// not reference them (they are defined in the PLAT archives; the table
// entry itself pulls them into the base link). The async-I2C driver uses
// the luatos core I2C API (soc_i2c.h: IRQ-driven, per-byte timeout,
// completion callback — unlike the timeout-less polling CMSIS blob).
FORCE-INCLUDE-EXACT ::= {
  "I2C_MasterSetup", "I2C_Prepare", "I2C_MasterXfer", "I2C_WaitResult",
  "I2C_BlockWrite", "I2C_BlockRead", "I2C_ChangeBR", "I2C_Reset",
  "I2C_UsePollingMode", "I2C_SetNoBlock",
  // The AON/wakeup-pad surface. The AON-domain GPIOs (pads 40..48) sit
  // behind the AON IO LDO: slpManAONIOPowerOn powers them (the GPIO
  // driver calls it when an AON pad is opened); the latch/voltage
  // functions are for the deep-sleep work.
  "GPIO_WakeupPadConfig", "GPIO_GlobalInit",
  // (slpManAONIOGetLatchCfg is declared in slpman.h but the PLAT libs
  // don't define it — adding it makes the link fail.)
  "slpManAONIOPowerOn", "slpManAONIOPowerOff",
  "slpManAONIOVoltSet", "slpManAONIOVoltGet",
  "slpManAONIOLatchEn",
  // The core SPI driver (soc_spi.h) — same IRQ-driven, no-block design as
  // the core I2C; the base links no SPI support otherwise.
  "SPI_MasterInit", "SPI_SetCallbackFun", "SPI_TransferEx",
  "SPI_BlockTransfer", "SPI_FastTransfer", "SPI_SetNoBlock",
  "SPI_FlashBlockTransfer", "SPI_TransferStop", "SPI_IsTransferBusy",
  "SPI_WaitTransferNoBusy", "SPI_SetDMAEnable", "SPI_SetNewConfig",
  "SPI_SetDMATrigger", "SPI_GetSpeed", "SPI_SetTxOnlyFlag",
}

// References with no PLAT definition — present only as dead, GC'd refs. A
// table entry would emit an undefined `__real_*`. Add here if a build fails
// with "undefined reference to ..." from plat_jt.o(.jt_data).
DEFAULT-EXCLUDE ::= {
  // toit::OS::set_writable — only defined for host (os_linux/win/darwin),
  // dead on embedded.
  "_ZN4toit2OS12set_writableEPNS_12ProgramBlockEb",
}

// Relocation types that denote a VM->PLAT call/jump.
CALL-RELOC-TYPES ::= {
  "R_ARM_THM_CALL",
  "R_ARM_CALL",
  "R_ARM_THM_JUMP24",
  "R_ARM_JUMP24",
  "R_ARM_THM_PC22",
  "R_ARM_PLT32",
}

HEADER-TEMPLATE ::= """\
// Copyright (C) 2026 Toit contributors.
// AUTO-GENERATED by $TOOL-NAME — do not edit by hand.
//
// PLAT jump table: one entry per PLAT-side symbol the VM reaches. The
// table is `const` and lives in `.rodata` (flash), so it is reachable
// before C-runtime `.data` initialisation runs. PLAT startup calls
// `memcpy` very early, which is the reason flash-resident matters.

#ifndef PLAT_JT_H_
#define PLAT_JT_H_

#ifdef __cplusplus
extern "C" {
#endif

enum plat_jt_slot {
{{slot_enum}}
    PLAT_JT_COUNT
};

extern void *const g_plat_jt[PLAT_JT_COUNT];

#ifdef __cplusplus
}
#endif

#endif  // PLAT_JT_H_
"""

SOURCE-TEMPLATE ::= """\
// Copyright (C) 2026 Toit contributors.
// AUTO-GENERATED by $TOOL-NAME — do not edit by hand.
//
// Per-symbol wrapper stubs + the jump-table data. Each stub is a
// 16-byte Thumb-2 sequence: load `g_plat_jt[slot]`, tail-call. The
// ABI args (r0-r3 + stack) are already in place by the time the BL
// from the caller lands, so a bare `bx` to the real function preserves
// every argument and return convention.

#include "plat_jt.h"

// Many table entries are libc/libm/compiler builtins (abort, memcpy, sin, ...).
// We declare each as `extern void *<sym>` only to take its address for the
// jump table — never to call it — so the builtin/non-function and any
// signedness mismatch is intentional and harmless. `&<sym>` still resolves to
// the real PLAT function (thumb bit intact), exactly as the old `&__real_<sym>`
// did under -Wl,--wrap.
#pragma GCC diagnostic ignored "-Wbuiltin-declaration-mismatch"

{{externs}}

// Placed at a fixed flash address (see ec618_0h00_flash.c, .jt_data
// section) so dual-linked VM slots resolve to the same g_plat_jt[]
// regardless of which slot's image they were linked from.
__attribute__((section(".jt_data"), used))
void *const g_plat_jt[PLAT_JT_COUNT] = {
{{table_init}}
};

#define PLAT_STUB(name, slot)                                       \\
    __attribute__((naked, noinline))                                 \\
    void __wrap_##name(void) {                                      \\
        __asm__ volatile (                                           \\
            "movw r12, #:lower16:g_plat_jt + " #slot " * 4 \\n"      \\
            "movt r12, #:upper16:g_plat_jt + " #slot " * 4 \\n"      \\
            "ldr  r12, [r12]                              \\n"       \\
            "bx   r12                                     \\n"       \\
        );                                                           \\
    }

{{stubs}}
"""

LDFLAGS-TEMPLATE ::= """\
-- AUTO-GENERATED by $TOOL-NAME — do not edit by hand.
-- Paste this block between the PLAT_JT_LDFLAGS markers in xmake.lua.
{{ldflags}}
"""

MARKER-BEGIN ::= "-- BEGIN PLAT_JT_LDFLAGS"
MARKER-END ::= "-- END PLAT_JT_LDFLAGS"

/**
Collects the symbols targeted by VM->PLAT call/jump relocations.

Runs `$objdump -r <archive>` for each archive in $archives and returns the
  referenced symbol names (with any `+0x..`/`-0x..` addend stripped).
*/
call-targets objdump/string archives/List -> Set:
  targets := {}
  archives.do: | arc/string |
    out := pipe.backticks [objdump, "-r", arc]
    out.split "\n": | line/string |
      // Relocation lines have the shape `<offset> <RELOC_TYPE> <symbol>`.
      parts := split-whitespace line
      if parts.size < 3: continue.split
      if not CALL-RELOC-TYPES.contains parts[1]: continue.split
      targets.add (strip-addend parts[2])
  return targets

/** Strips a trailing `+0x..` or `-0x..` addend from a relocation symbol. */
strip-addend symbol/string -> string:
  plus := symbol.index-of "+"
  minus := symbol.index-of "-"
  cut := -1
  if plus >= 0: cut = plus
  if minus >= 0 and (cut == -1 or minus < cut): cut = minus
  if cut == -1: return symbol
  return symbol[..cut]

/**
Collects the symbols defined in the given $files.

Runs `$nm --defined-only <file>` and returns the 3rd field (the symbol name)
  of every `<addr> <type> <name>` line.
*/
defined-symbols nm/string files/List -> Set:
  defined := {}
  files.do: | f/string |
    out := pipe.backticks [nm, "--defined-only", f]
    out.split "\n": | line/string |
      parts := split-whitespace line
      if parts.size >= 3: defined.add parts[2]
  return defined

/** Collects all symbols (defined or not) reported by `$nm <file>`. */
all-symbols nm/string file/string -> Set:
  result := {}
  out := pipe.backticks [nm, file]
  out.split "\n": | line/string |
    parts := split-whitespace line
    if parts.is-empty: continue.split
    // Lines are `<addr> <type> <name>` or `<type> <name>` (undefined).
    result.add parts.last
  return result

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

/** Whether $name belongs to the curated "always-include" API surface. */
matches-always-include name/string -> bool:
  if ALWAYS-INCLUDE-EXACT.contains name: return true
  ALWAYS-INCLUDE-PREFIXES.do: | prefix/string |
    if name.starts-with prefix: return true
  return false

/**
Returns the curated "always-include" PLAT API symbols actually defined in $elf.

Reads `$nm --defined-only $elf` and keeps every STRONG global function (`T`)
  whose address falls OUTSIDE the VM slot `[$lo, $hi)` (so it is a fixed PLAT
  symbol, not VM/slot code) and whose name $matches-always-include. These are
  merged into the relocation-derived set so the frozen jump-table ABI covers
  PLAT functions a future firmware may call even if the current VM does not.
*/
plat-api-functions nm/string elf/string lo/int hi/int -> Set:
  result := {}
  out := pipe.backticks [nm, "--defined-only", elf]
  out.split "\n": | line/string |
    parts := split-whitespace line
    if parts.size < 3: continue.split
    addr := int.parse parts[0] --radix=16 --if-error=: continue.split
    if parts[1] != "T": continue.split          // Strong global functions only.
    name := parts[2]
    if lo <= addr and addr < hi: continue.split  // Skip the VM slot itself.
    if matches-always-include name: result.add name
  return result

/**
Returns the VM slot link range `[lo, hi]` from `$nm $elf`.

Prefers `__vm_link_base`/`__vm_link_end` (the neutral link VMA the slot image's
  code lives at); falls back to `__vm_b_start`/`__vm_b_end`. Mirrors
  check-slot-pic.toit / check-slot-refs.toit.
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
  if a-start != null and a-end != null and a-start != a-end: return [a-start, a-end]
  b-start := symbols.get "__vm_b_start"
  b-end := symbols.get "__vm_b_end"
  if b-start != null and b-end != null: return [b-start, b-end]
  if a-start != null and a-end != null: return [a-start, a-end]
  return [0, 0]

/** Derives the final, sorted symbol list for the jump table. */
extract-symbols --objdump/string --nm/string --elf/string --archives/List --excludes/List -> List:
  targets := call-targets objdump archives
  vm-defined := defined-symbols nm archives
  elf-defined := all-symbols nm elf
  exclude := {}
  exclude.add-all DEFAULT-EXCLUDE
  exclude.add-all DATA-SYMBOLS
  exclude.add-all excludes

  result := {}
  targets.do: | sym/string |
    // The archives may already be `objcopy --redefine-syms`-rewritten by a
    // previous build (<sym> -> __wrap_<sym>). Extraction must see the plain
    // name, or a regen against built archives emits double-wrapped entries
    // (__real___wrap_<sym>). The manual libc time shims are the exception:
    // their __wrap_ name is the real PLAT symbol.
    s := sym
    if s.starts-with "__wrap_" and not (MANUAL-WRAP.contains s[7..]): s = s[7..]
    if vm-defined.contains s: continue.do
    if exclude.contains s: continue.do
    // A mangled C++ reference that resolves to nothing in the final elf is
    // dead VM code; skip it (avoids an undefined __real_*). Plain-C
    // libc/libgcc refs may be GC'd here but the table's KEEP pulls them
    // back, so don't filter those.
    if s.starts-with "_Z" and not (elf-defined.contains s): continue.do
    result.add (MANUAL-WRAP.contains s ? "__wrap_$s" : s)

  // Merge the curated "always-include" API surface (the generous ABI). Each is
  // a fixed PLAT function already defined in the elf, so it adds only a table
  // slot + an in-slot stub — never wrapped (none are in MANUAL-WRAP) and never
  // VM-defined (filtered by the slot range).
  range := slot-range nm elf
  generous := plat-api-functions nm elf range[0] range[1]
  generous.do: | s/string |
    if vm-defined.contains s: continue.do
    if exclude.contains s: continue.do
    result.add s

  result.add-all FORCE-INCLUDE-EXACT

  sorted := []
  sorted.add-all result
  // Codepoint sort: deterministic and locale-independent. The order only
  // fixes the (internal) jump-table indices, so any stable order is fine.
  sorted.sort --in-place
  return sorted

/** Patches the lines between the PLAT_JT_LDFLAGS markers with $ldflags-body. */
patch-xmake xmake-path/string ldflags-body/string -> none:
  text := (file.read-contents xmake-path).to-string
  begin := text.index-of MARKER-BEGIN
  end := text.index-of MARKER-END
  if begin == -1 or end == -1 or end < begin:
    throw "$xmake-path: missing PLAT_JT_LDFLAGS markers"
  // Replace everything between the marker lines (inclusive of the begin
  // marker's end-of-line up to the end marker).
  before := text[..begin + MARKER-BEGIN.size]
  after := text[end..]
  file.write-contents --path=xmake-path "$before\n$ldflags-body\n$after"

main args:
  cmd := cli.Command "gen-plat-jt"
      --help="""
        Extracts the VM->PLAT call symbol set from the VM archives and
        generates plat_jt.h, plat_jt.c, the ldflags fragment, and patches
        the PLAT_JT_LDFLAGS block in xmake.lua.
        """
      --options=[
        cli.Option "objdump"
            --help="The arm objdump binary."
            --default="arm-none-eabi-objdump",
        cli.Option "nm"
            --help="The arm nm binary."
            --default="arm-none-eabi-nm",
        cli.Option "elf"
            --help="The final linked toit.elf (used to drop dead C++ refs)."
            --required,
        cli.Option "header"
            --help="The output plat_jt.h path."
            --required,
        cli.Option "source"
            --help="The output plat_jt.c path."
            --required,
        cli.Option "ldflags"
            --help="The output ldflags .lua fragment path."
            --required,
        cli.Option "redefine"
            --help="The output `objcopy --redefine-syms` map path (VM archive rewrite)."
            --required,
        cli.Option "xmake"
            --help="The xmake.lua to patch."
            --required,
        cli.Option "exclude"
            --help="Extra symbol to exclude (repeatable)."
            --multi,
      ]
      --rest=[
        cli.Option "archive"
            --help="VM archives (libtoit_vm.a, libmbed*.a)."
            --required
            --multi,
      ]
      --run=:: run it
  cmd.run args

run invocation/cli.Invocation -> none:
  objdump := invocation["objdump"]
  nm := invocation["nm"]
  elf := invocation["elf"]
  header-path := invocation["header"]
  source-path := invocation["source"]
  ldflags-path := invocation["ldflags"]
  redefine-path := invocation["redefine"]
  xmake-path := invocation["xmake"]
  excludes := invocation["exclude"]
  archives := invocation["archive"]

  symbols := extract-symbols
      --objdump=objdump
      --nm=nm
      --elf=elf
      --archives=archives
      --excludes=excludes

  if symbols.is-empty:
    pipe.print-to-stderr "no symbols found in input"
    exit 1

  // Wrapping strategy (the "wrap only the VM" model — see Option M in
  // docs/ota-relocation-convergence.md): the VM-side calls must reach the
  // in-slot stubs (for position independence), but PLAT/RAM-resident code must
  // NOT — a PLAT call to an in-slot stub faults if that slot is the one being
  // erased during a B->A OTA. `-Wl,--wrap` is global (it rewrites PLAT's calls
  // too), so instead the build `objcopy --redefine-syms`-rewrites only the VM
  // archives' references `<sym> -> __wrap_<sym>`, and the final link drops the
  // `--wrap`. PLAT then keeps calling the real symbols directly. The jump table
  // therefore references the REAL symbols (`&<sym>`), not `--wrap`'s `__real_`.
  //
  // EXCEPTION: the manual libc time shims live in PLAT (__wrap.c) at fixed
  // addresses, reached by the VM via `--wrap=time` -> `__wrap_time`. They are
  // not in-slot, so they are not part of the hazard; those `__wrap_*` entries
  // keep the `--wrap` + `__real_` mechanism untouched.
  slot-enum-lines := []
  externs-lines := []
  table-init-lines := []
  stubs-lines := []
  ldflags-lines := []
  redefine-lines := []  // `objcopy --redefine-syms` map: `<sym> __wrap_<sym>`.
  symbols.size.repeat: | i/int |
    s := symbols[i]
    keep-wrap := s.starts-with "__wrap_"
    slot-enum-lines.add "    PLAT_JT_$s = $i,"
    stubs-lines.add "PLAT_STUB($s, $i)"
    if keep-wrap:
      externs-lines.add "extern void *__real_$s;"
      table-init-lines.add "    [PLAT_JT_$s] = &__real_$s,"
      ldflags-lines.add "add_ldflags(\" -Wl,--wrap=$s \", {force = true})"
    else:
      // Reference the real PLAT symbol directly; the VM archive is rewritten to
      // call `__wrap_$s` (the stub) via objcopy, so the real `$s` is reached
      // only by PLAT and by this table entry.
      externs-lines.add "extern void *$s;"
      table-init-lines.add "    [PLAT_JT_$s] = &$s,"
      redefine-lines.add "$s __wrap_$s"

  slot-enum := slot-enum-lines.join "\n"
  externs := externs-lines.join "\n"
  table-init := table-init-lines.join "\n"
  stubs := stubs-lines.join "\n"
  ldflags := ldflags-lines.join "\n"
  redefine := redefine-lines.join "\n"

  header := HEADER-TEMPLATE.replace "{{slot_enum}}" slot-enum
  source := SOURCE-TEMPLATE.replace "{{externs}}" externs
  source = source.replace "{{table_init}}" table-init
  source = source.replace "{{stubs}}" stubs
  ldflags-fragment := LDFLAGS-TEMPLATE.replace "{{ldflags}}" ldflags

  file.write-contents --path=header-path header
  file.write-contents --path=source-path source
  file.write-contents --path=ldflags-path ldflags-fragment
  file.write-contents --path=redefine-path "$redefine\n"
  patch-xmake xmake-path ldflags

  print "Generated $symbols.size stubs ($redefine-lines.size objcopy-rewritten, $ldflags-lines.size kept --wrap)."
  print "  header:   $header-path"
  print "  source:   $source-path"
  print "  ldflags:  $ldflags-path"
  print "  redefine: $redefine-path"
  print "  xmake.lua: patched"
