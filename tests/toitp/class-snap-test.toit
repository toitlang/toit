// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.snapshot

main args:
  snapshot-path := args[0]
  snapshot := SnapshotBundle.from-file snapshot-path
  program := snapshot.decode

  class-A-id /int? := null
  class-B-id /int? := null
  program.class-tags.size.repeat:
    name := program.class-name-for it
    if name == "ClassA": class-A-id = it
    if name == "ClassB": class-B-id = it
  expect-not-null class-A-id
  expect-not-null class-B-id

  a-info /ClassInfo := program.class-info-for class-A-id
  expect-equals 1 a-info.fields.size
  expect-equals "field" a-info.fields.first

  b-info /ClassInfo := program.class-info-for class-B-id
  expect-equals 1 b-info.fields.size
  expect-equals "field-b" b-info.fields.first

  expect-equals a-info.id b-info.super-id
  expect-equals 0 a-info.super-id
  expect-null (program.class-info-for 0).super-id
