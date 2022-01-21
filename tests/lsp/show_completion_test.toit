// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .imported2 show ExportedClass
/*                     ^~~~~~~~~~~~~
  + ExportedClass, ExportedClass2, foo
  - List
*/

// Would be nice if we wouldn't suggest `ExportedClass` again.
// See https://github.com/toitware/toit/issues/612
import .imported2 show ExportedClass ExportedClass2
/*                                   ^~~~~~~~~~~~~~
  + ExportedClass, ExportedClass2, foo
  - List
*/

import .imported3 show foo
/*                     ^~~
  + ExportedClass, ExportedClass2, foo
  - *
*/

import .imported4 show List
/*                     ^~~~
  + List, Map
*/
