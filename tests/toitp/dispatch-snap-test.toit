// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.snapshot

main args:
  snapshot-path := args[0]
  snapshot := SnapshotBundle.from-file snapshot-path
  program := snapshot.decode

  dispatch := program.dispatch-table

  a-foo-info := null
  a-bar-info := null
  b-bar-info := null
  program.do --method-infos: | method |
    if method.name == "test-foo":
      a-foo-info = method
    else if method.name == "test-bar":
      outer-name := program.class-name-for method.outer
      if outer-name == "ClassA":
        a-bar-info = method
      else:
        b-bar-info = method

  expect-not-null a-foo-info
  expect-not-null a-bar-info
  expect-not-null b-bar-info

  // We expect two entries of a_method_a in the dispatch table.
  foo-id := a-foo-info.id
  found-foo := false;
  for i := 0; i < dispatch.size - 1; i++:
    if dispatch[i] == foo-id:
      found-foo = true
      expect dispatch[i + 1] == foo-id
      expect ((i + 2 == dispatch.size) or (dispatch[i + 2] != foo-id))
      break
  expect found-foo

  // We expect b_bar to be just after a_bar.
  a-bar-id := a-bar-info.id
  b-bar-id := b-bar-info.id
  found-bar := false;
  for i := 0; i < dispatch.size - 1; i++:
    if dispatch[i] == a-bar-id:
      found-bar = true
      expect dispatch[i + 1] == b-bar-id
      expect ((i + 2 == dispatch.size) or ((dispatch[i + 2] != a-bar-id and dispatch[i + 2] != b-bar-id)))
      break
  expect found-bar
