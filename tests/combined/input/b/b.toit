// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// An application that ignores the arguments. It uses another version of
// the package than the first one.
import foo show *

main:
  print "b: $foo-name"
