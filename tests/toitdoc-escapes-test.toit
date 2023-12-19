// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that the toitdoc compiler can deal with escapes.
The health-check of this test must not have any warnings.
*/

/**
- `\\`
- `\\\\`
- "\""
- "\\\"\\"
*/
foo:

main:
  // Do nothing.
  // The test relies on the health-check to detect errors.
