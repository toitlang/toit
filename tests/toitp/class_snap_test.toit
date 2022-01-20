// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.snapshot

main args:
  snapshot_path := args[0]
  snapshot := SnapshotBundle.from_file snapshot_path
  program := snapshot.decode

  class_A_id /int? := null
  class_B_id /int? := null
  program.class_tags.size.repeat:
    name := program.class_name_for it
    if name == "ClassA": class_A_id = it
    if name == "ClassB": class_B_id = it
  expect_not_null class_A_id
  expect_not_null class_B_id

  a_info /ClassInfo := program.class_info_for class_A_id
  expect_equals 1 a_info.fields.size
  expect_equals "field" a_info.fields.first

  b_info /ClassInfo := program.class_info_for class_B_id
  expect_equals 1 b_info.fields.size
  expect_equals "field_b" b_info.fields.first

  expect_equals a_info.id b_info.super_id
  expect_equals 0 a_info.super_id
  expect_null (program.class_info_for 0).super_id
