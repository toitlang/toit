// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .import_completion_test as pre
/*      ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  + import-completion-test, import-definition-test, dir
  - SomeClass, member, main, core
*/

import core as core
/*     ^~~~~~~~~~~~
  + core
  - completion-imported
*/

import core.collections as col
/*          ^~~~~~~~~~~~~~~~~~
  + collections, core
  - completion-imported
*/

import .dir.in_dir as dir
/*          ^~~~~~~~~~~~~
  + in-dir
  - import-completion-test, core
*/

import core.collections.invalid
/*                      ^~~~~~~
  - *
*/

main:
