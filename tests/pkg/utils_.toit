// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.pipe

unzip --source/string --target-dir/string -> none:
  // Unzip the given 'source' zip file into the 'target-dir'.
  exit-value := pipe.run-program ["unzip", "-q", "-d", target-dir, source]
  if exit-value != 0:
    exit-signal := pipe.exit-signal exit-value
    exit-code := pipe.exit-code exit-value
    throw "Failed to unzip '$source' into '$target-dir': $exit-value/$exit-signal"
