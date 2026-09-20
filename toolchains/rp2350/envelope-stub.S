// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

// The envelope extractor patches DromData to its appended system/container
// extension. This placeholder deliberately has no runnable system image.
.section .rodata.toit_program,"a",%progbits
.balign 4096
.global toit_embedded_extension
toit_embedded_extension:
.long 0x98dfc301, 4096, 0, 0, (0x98dfc301 ^ 4096 ^ 0xb3147ee9)
.global toit_program_uuid
toit_program_uuid:
.space 16
.balign 4096
