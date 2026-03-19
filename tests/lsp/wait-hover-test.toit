// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.pipe

main:
  process := pipe.fork "ls" ["ls"]
  process.wait
  /*      ^
  Wait for the process to finish and return the exit-value.
  */
