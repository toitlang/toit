/* Copyright (C) 2026 Toit contributors.
 * Use of this source code is governed by the LGPL-2.1 license in LICENSE. */

SECTION_PROLOGUE(.toit_extension,,ALIGN(4096))
{
  KEEP(*(.toit.extension))
} GROUP_LINK_IN(ROMABLE_REGION)
