// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.snapshot

main args:
  snapshot_path := args[0]
  snapshot := SnapshotBundle.from_file snapshot_path
  program := snapshot.decode

  found_string := null
  found_byte_array := null

  program.literals.do:
    if it is ToitString and it.content.size == 33488: found_string = it.content.to_string
    if it is ToitByteArray and it.content.size == 33488: found_byte_array = it.content

  expect_not_null found_string
  expect_equals found_string found_byte_array.to_string
