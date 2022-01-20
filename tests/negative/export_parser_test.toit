// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

export 4
export
export 4  // comment
export    // comment
export 4  /* comment
  multiline */
export    /* comment
  multiline */

main:
  print 1
