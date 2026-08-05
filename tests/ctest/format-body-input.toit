// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

sample x:
  x  +   1  // Keep   every byte.
  if not x:
    // Do nothing.
  if  x:  // Keep   header bytes.
    return    1
  // This belongs to the outer body.
  if x:
    x
    /* Avoid joining
       the two lines. */
    return 499
  x/*attached*/
  return   x  // Keep   return bytes.
  /* Last body comment. */

main:
  sample true
