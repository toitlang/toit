// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

// Deliberately leaves startup arguments unread and exercises the private GC spare.
main:
  3.repeat:
    retained := List 100: ByteArray 100 --initial=it
    system.process-stats --gc
    if retained[42][0] != 42: throw "GC_CORRUPTED_VALUE"
