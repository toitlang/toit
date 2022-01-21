// Keep this comment, as '@ import_definition_test' needs a line to point to.
/*
@ import_definition_test
*/

// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .import_definition_test as pre
/*         ^
  [import_definition_test]
*/

import core as core
/*      ^
  [core.core]
*/

import core.collections as col
/*           ^
  [core.collections]
*/

import .dir.in_dir as dir1
/*       ^
  [in_dir]
*/

import .dir.in_dir as dir2
/*           ^
  [in_dir]
*/

main:
