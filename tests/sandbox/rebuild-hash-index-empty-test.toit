// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// rebuild_hash_index with an empty index array used to index out of bounds.
main args:
  sandbox-test args --error="INVALID_ARGUMENT": | arguments/Map |
    rebuild-hash-index_ (Array_ 1 12345) (Array_ 0)

rebuild-hash-index_ old new:
  #primitive.core.rebuild-hash-index
