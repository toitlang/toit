// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Run with 'toit run --untrusted'. Denied primitives throw.
main:
  print "hostname: $(catch: hostname_)"
  print "file: $(catch: file-open_ "/etc/passwd" 0 0)"

hostname_:
  #primitive.core.hostname

file-open_ path flags mode:
  #primitive.file.open
