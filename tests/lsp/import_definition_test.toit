// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
/*
@ import_definition_test
*/

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
