// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .imported2 show ExportedClass
/*                      ^
  [ExportedClass]
*/

import .imported2 show ExportedClass ExportedClass2
/*                                     ^
  [ExportedClass2]
*/

import .imported3 show foo
/*                     ^
  [foo1, foo2]
*/
