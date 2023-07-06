// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.snapshot

main args:
  snapshot_path := args[0]
  snapshot := SnapshotBundle.from_file snapshot_path
  program := snapshot.decode

  // We must not see `B`, and `C.foo`.
  program.do --class_infos: | klass/ClassInfo |
    expect_not_equals "B" klass.name

  program.do --method_infos: | method/MethodInfo |
    if method.type != MethodInfo.INSTANCE_TYPE:
      continue.do
    class_name := program.class_name_for method.outer
    if class_name != "C":
      continue.do
    expect_not_equals "foo" method.name
