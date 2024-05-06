// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io

main:
  reader := io.Reader #[1, 2, 3, 4]
  reader.skip 2
  expect-equals #[3, 4] (reader.read-bytes 2)
