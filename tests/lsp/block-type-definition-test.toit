// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .definition-imported as prefix

class SomeClass:
/*    @ SomeClass */

param-type [b SomeClass]:
/*            ^
  [SomeClass]
*/
  b.call SomeClass

return-type [b -> SomeClass]:
/*                ^
  [SomeClass]
*/
  b.call

prefixed [b prefix.ImportedClass]:
/*                 ^
  [ImportedClass]
*/
  b.call prefix.ImportedClass

named [--b SomeClass -> none]:
/*         ^
  [SomeClass]
*/
  b.call SomeClass

main:
  param-type: |x/SomeClass| x
/*               ^
  [SomeClass]
*/
