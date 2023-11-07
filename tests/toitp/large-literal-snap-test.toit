// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.snapshot

main args:
  snapshot-path := args[0]
  snapshot := SnapshotBundle.from-file snapshot-path
  program := snapshot.decode

  found-string := null
  found-byte-array := null

  program.literals.do:
    if it is ToitString and it.content.size == 33488: found-string = it.content.to-string
    if it is ToitByteArray and it.content.size == 33488: found-byte-array = it.content

  expect-not-null found-string
  expect-equals found-string found-byte-array.to-string
