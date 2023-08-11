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
  program.class-tags.size.repeat:
    name := program.class-name-for it
    if name == "ClassA": class-A-id = it
  expect-not-null class-A-id

  expect program.class-instance-sizes[class-A-id] >= 48
