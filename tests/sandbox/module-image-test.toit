// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Writing firmware images is denied.
main args:
  sandbox-test args --error="PRIMITIVE_LOOKUP_FAILED": | arguments/Map |
    image-writer-create_ 0 0

image-writer-create_ offset size:
  #primitive.image.writer-create
