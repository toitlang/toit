// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Goto-definition on keywords, such as `import` and `class` used to crash the compiler.
import encoding.json as json
/* ^
  []
*/

class A:
/* ^
  []
*/

main:
