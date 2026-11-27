// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

sample:
  value := 1  // Keep   every byte.
  // This comment is on its own line.
  value := /* Attached
               alignment. */ 2
  /* Standalone
     block. */
