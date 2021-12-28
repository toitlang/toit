// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .imported2
import .imported2 as pre
import .imported4 as pre2
import .export_completion_test as pre3

export *

top_level: return null

main:
    // Comment is needed, so that the spaces aren't removed.
/*^
  + Map, ExportedClass, ExportedClass2
  - member
*/
  some := ExportedClass
/*        ^~~~~~~~~~~~~
  + Map, ExportedClass, ExportedClass2
  - member
*/

  some2 := pre.ExportedClass
/*             ^~~~~~~~~~~~~
  + ExportedClass, ExportedClass2, foo
  - List, Map
*/

  some3 := pre2.List
/*              ^~~~
  + List, Map
*/

  some4 := pre3.top_level
/*              ^~~~~~~~~
  + top_level, main, ExportedClass, ExportedClass2, foo
  - *
*/
