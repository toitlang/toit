// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.snapshot

main args:
  snapshot_path := args[0]
  snapshot := SnapshotBundle.from_file snapshot_path
  program := snapshot.decode

  dispatch := program.dispatch_table

  a_foo_info := null
  a_bar_info := null
  b_bar_info := null
  program.do --method_infos: | method |
    if method.name == "test_foo":
      a_foo_info = method
    else if method.name == "test_bar":
      outer_name := program.class_name_for method.outer
      if outer_name == "ClassA":
        a_bar_info = method
      else:
        b_bar_info = method

  expect_not_null a_foo_info
  expect_not_null a_bar_info
  expect_not_null b_bar_info

  // We expect two entries of a_method_a in the dispatch table.
  foo_id := a_foo_info.id
  found_foo := false;
  for i := 0; i < dispatch.size - 1; i++:
    if dispatch[i] == foo_id:
      found_foo = true
      expect dispatch[i + 1] == foo_id
      expect ((i + 2 == dispatch.size) or (dispatch[i + 2] != foo_id))
      break
  expect found_foo

  // We expect b_bar to be just after a_bar.
  a_bar_id := a_bar_info.id
  b_bar_id := b_bar_info.id
  found_bar := false;
  for i := 0; i < dispatch.size - 1; i++:
    if dispatch[i] == a_bar_id:
      found_bar = true
      expect dispatch[i + 1] == b_bar_id
      expect ((i + 2 == dispatch.size) or ((dispatch[i + 2] != a_bar_id and dispatch[i + 2] != b_bar_id)))
      break
  expect found_bar
