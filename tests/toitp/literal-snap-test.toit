// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.snapshot

main args:
  snapshot-path := args[0]
  snapshot := SnapshotBundle.from-file snapshot-path
  program := snapshot.decode

  found-string := false
  found-large-int := false
  found-float := false

  program.literals.do:
    if it is ToitString and it.content.to-string == "foo": found-string = true
    if it is ToitInteger and it.value == 0x123456789ABCDEF: found-large-int = true
    if it is ToitFloat and it.value == 12.345: found-float = true

  expect found-string
  expect found-large-int
  expect found-float
