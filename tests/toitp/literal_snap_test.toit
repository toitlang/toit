// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *
import ...tools.snapshot

main args:
  snapshot_path := args[0]
  snapshot := SnapshotBundle.from_file snapshot_path
  program := snapshot.decode

  found_string := false
  found_large_int := false
  found_float := false

  program.literals.do:
    if it is ToitString and it.content.to_string == "foo": found_string = true
    if it is ToitInteger and it.value == 0x123456789ABCDEF: found_large_int = true
    if it is ToitFloat and it.value == 12.345: found_float = true

  expect found_string
  expect found_large_int
  expect found_float
