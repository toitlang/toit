// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.snapshot

main args:
  snapshot-path := args[0]
  snapshot := SnapshotBundle.from-file snapshot-path
  program := snapshot.decode

  // We must not see `B`, and `C.foo`.
  program.do --class-infos: | klass/ClassInfo |
    expect-not-equals "B" klass.name

  program.do --method-infos: | method/MethodInfo |
    if method.type != MethodInfo.INSTANCE-TYPE:
      continue.do
    class-name := program.class-name-for method.outer
    if class-name != "C":
      continue.do
    expect-not-equals "foo" method.name
