// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// The pipe module (host processes) is denied.
main args:
  sandbox-test args --error="PRIMITIVE_LOOKUP_FAILED": | arguments/Map |
    pipe-init_

pipe-init_:
  #primitive.pipe.init
