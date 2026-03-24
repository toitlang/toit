// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: SDK fields cannot be renamed.

import gpio

main:
  pin := gpio.Pin 18
  _ := pin.num
/*         ^
  0
*/
