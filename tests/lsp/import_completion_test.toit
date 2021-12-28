// Copyright (C) 2020 Toitware ApS. All rights reserved.

import .import_completion_test as pre
/*      ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  + import_completion_test, import_definition_test, dir
  - SomeClass, member, main, core
*/

import core as core
/*     ^~~~~~~~~~~~
  + core
  - completion_imported
*/

import core.collections as col
/*          ^~~~~~~~~~~~~~~~~~
  + collections, core
  - completion_imported
*/

import .dir.in_dir as dir
/*          ^~~~~~~~~~~~~
  + in_dir
  - import_completion_test, core
*/
main:
