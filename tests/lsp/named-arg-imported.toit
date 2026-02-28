// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Helper file for named-arg-call-prepare-rename-test.toit.
// Provides functions with named parameters that are called from the test file.

imported-function hostname/string --network/string --timeout/int=5 -> string:
  return hostname
