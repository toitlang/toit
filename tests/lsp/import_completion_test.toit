// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

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
