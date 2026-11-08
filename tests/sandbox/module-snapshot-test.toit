// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Launching programs from bytes is denied (and PRIVILEGED).
main args:
  sandbox-test args --error="PRIMITIVE_LOOKUP_FAILED": | arguments/Map |
    launch_ #[] 0 (ByteArray 16) [] 1

launch_ bytes gid id arguments policy:
  #primitive.snapshot.launch
