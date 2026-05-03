// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: named argument at call site resolves to the parameter.

import .named-arg-imported

some-function --my-option/bool --count/int:
  return count

main:
  some-function --my-option --count=3
/*                ^
  my-option
*/
  some-function --my-option --count=3
/*                             ^
  count
*/
  // Named argument inside parenthesized call (like (dns-lookup x --network=y).foo).
  (some-function --my-option --count=7)
/*                  ^
  my-option
*/
  (some-function --my-option --count=7)
/*                              ^
  count
*/
  // Named argument where result is chained with a member access (like the udp.toit pattern).
  (some-function --count=7 --my-option).hash-code
/*                  ^
  count
*/
  // Cross-module: named argument calling an imported function.
  imported-function "hello" --network="wifi"
/*                             ^
  network
*/
  imported-function "hello" --network="wifi" --timeout=10
/*                                              ^
  timeout
*/
  // Cross-module: parenthesized with member access (like udp.toit pattern).
  (imported-function "hello" --network="wifi").size
/*                              ^
  network
*/
