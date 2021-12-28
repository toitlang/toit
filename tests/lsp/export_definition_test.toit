// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .imported2
import .export_definition_test as pre
import .imported4 as pre2
export *

class List:
/*    @ List */

main:
  some := ExportedClass
/*         ^
  [ExportedClass]
*/

  some2 := ExportedClass2
/*         ^
  [ExportedClass2]
*/

  some3 := pre.List
/*               ^
  [List]
*/

  some4 := pre2.List
/*
  [core.List]
*/
