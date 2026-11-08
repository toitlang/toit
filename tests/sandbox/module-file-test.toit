// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// The file module (host file system) is denied.
main args:
  sandbox-test args --error="PRIMITIVE_LOOKUP_FAILED": | arguments/Map |
    file-open_ "/etc/passwd" 0 0

file-open_ path/string flags/int mode/int:
  #primitive.file.open
