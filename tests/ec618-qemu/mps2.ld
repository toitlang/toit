/* Copyright (C) 2026 Toit contributors.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; version
 * 2.1 only.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * The license can be found in the file `LICENSE` in the top level
 * directory of this repository.
 */

/* The EC618 VM library on QEMU's mps2-an385 (Cortex-M3): code and
 * read-only data in ZBT SSRAM1 (4 MB at 0), data, stacks and the heap in
 * SSRAM2/3 (4 MB at 0x20000000). The heap has the EC618 base's size
 * (heap_size = start_up_buffer - end_ap_data, 0x567c0 bytes for base v5)
 * unless HEAP_SIZE is given with --defsym. The bundled extension (the
 * images, built by extension.toit for EXTENSION_ADDRESS) and the emulated
 * flash registry are in the PSRAM (16 MB at 0x21000000), loaded by QEMU. */

MEMORY
{
  CODE (rx)  : ORIGIN = 0x00000000, LENGTH = 4M
  RAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 4M
}

HEAP_SIZE = DEFINED(HEAP_SIZE) ? HEAP_SIZE : 0x567c0;
MAIN_STACK_SIZE = 0x2000;

ENTRY(Reset_Handler)

/* No crt objects (-nostartfiles), as in the slot link. */
PROVIDE(__dso_handle = 0);

SECTIONS
{
  .vectors 0x00000000 :
  {
    KEEP(*(.vectors))
  } > CODE

  .text :
  {
    *(.text*)
    *(.glue_7) *(.glue_7t) *(.vfpll_veneer) *(.v4_bx)
    . = ALIGN(4);
    *(.rodata*)
    . = ALIGN(4);
    __init_array_start = .;
    KEEP(*(SORT(.init_array.*)))
    KEEP(*(.init_array*))
    __init_array_end = .;
    . = ALIGN(4);
  } > CODE

  .ARM.exidx :
  {
    *(.ARM.exidx*)
  } > CODE

  __data_load = LOADADDR(.data);
  .data :
  {
    __data_start = .;
    *(.data*)
    . = ALIGN(4);
    __data_end = .;
  } > RAM AT > CODE

  .bss (NOLOAD) :
  {
    __bss_start = .;
    *(.bss*)
    *(COMMON)
    *(.toit.rtc.noinit)
    . = ALIGN(8);
    __bss_end = .;
  } > RAM

  .stack (NOLOAD) :
  {
    . = ALIGN(8);
    . += MAIN_STACK_SIZE;
    __main_stack_top = .;
  } > RAM

  /* The names of the EC618 base (heap_7.c). */
  .heap (NOLOAD) :
  {
    . = ALIGN(16);
    end_ap_data = .;
    . += HEAP_SIZE;
    start_up_buffer = .;
  } > RAM

  /DISCARD/ :
  {
    *(.ARM.extab*)
    *(.comment)
  }
}
