// Copyright (C) 2019 Toitware ApS. All rights reserved.

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
