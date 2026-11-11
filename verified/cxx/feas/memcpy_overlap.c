/* Copyright (C) 2026 Toit contributors.
 * Probe: does the tool report an overlapping memcpy (undefined behavior,
 * the bug af4ba7ab fixed in string_write_to_byte_array)?
 *   esbmc memcpy_overlap.c
 *   cbmc memcpy_overlap.c --pointer-check --bounds-check
 */
#include <string.h>

unsigned char nondet_uchar(void);

int main(void) {
  unsigned char a[8];
  for (int i = 0; i < 8; i++) a[i] = nondet_uchar();
  unsigned char b1 = a[1];
  memcpy(a + 2, a + 1, 4);  /* Overlapping: UB. */
  /* memmove semantics would give a[2] == old a[1]. */
  __CPROVER_assert(a[2] == b1, "memmove semantics");
  return 0;
}
