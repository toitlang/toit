// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .definition-imported
import .definition-imported as prefix

class SomeClass:

param-type [b SomeClass]:
/*            ^~~~~~~~~~
  + SomeClass, any, ImportedInterface, prefix
  - param-type, none, null
*/
  b.call SomeClass

return-type [b -> SomeClass]:
/*                ^~~~~~~~~~
  + SomeClass, any, ImportedInterface, prefix, none
  - return-type, null
*/
  b.call

prefixed [b prefix.ImportedClass -> none]:
/*                 ^~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, ImportedInterface, ImportedMixin
  - *
*/
  b.call prefix.ImportedClass

named [--b ImportedClass -> ImportedClass]:
/*         ^~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, any, SomeClass, prefix
  - none, named, null
*/
  b.call ImportedClass
