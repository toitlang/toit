// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *
import ...tools.snapshot

main args:
  snapshot_path := args[0]
  snapshot := SnapshotBundle.from_file snapshot_path
  program := snapshot.decode

  class_A_id /int? := null
  program.class_tags.size.repeat:
    name := program.class_name_for it
    if name == "ClassA": class_A_id = it
  expect_not_null class_A_id

  expect program.class_instance_sizes[class_A_id] >= 48
