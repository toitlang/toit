// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *
import ...tools.snapshot

main args:
  snapshot_path := args[0]
  snapshot := SnapshotBundle.from_file snapshot_path
  program := snapshot.decode

  needles := {
    "A.foo",
    "bar",
    "B.gee",
    "C.toto",
  }

  per_method_name := {:}
  needles.do:
    method_name := null
    outer_name := null
    if it.contains ".":
      parts := it.split "."
      method_name = parts[1]
      outer_name = parts[0]
    else:
      method_name = it
      outer_name = ""
    (per_method_name.get method_name --init=:{}).add outer_name

  found_methods := {:}
  program.do --method_infos: | method/MethodInfo |
    if per_method_name.contains method.name:
      outer_name := ""
      if method.type == MethodInfo.INSTANCE_TYPE:
        outer_name = (program.class_name_for method.outer)
      else if method.type == MethodInfo.TOP_LEVEL_TYPE:
        outer_name = method.holder_name or ""
      if per_method_name[method.name].contains outer_name:
        prefix := outer_name == "" ? "" : "$(outer_name)."
        (found_methods.get "$(prefix)$method.name" --init=:[]).add method

  // Check that all needles are found.
  needles.do:
    expect (found_methods.contains it)

  // Do some spot checks.
  foo /MethodInfo := found_methods["A.foo"][0]
  bar /MethodInfo := found_methods["bar"][0]
  gee /MethodInfo := found_methods["B.gee"][0]
  toto /MethodInfo := found_methods["C.toto"][0]

  // The following checks are checking the correctness of
  // our source mapping.
  expect_equals "A" foo.holder_name
  expect_null bar.holder_name
  expect_equals "B" gee.holder_name
  expect_equals "C" toto.holder_name
  expect_null bar.outer  // Bar doesn't have an outer.

  // The following checks might diverge over time. They check a specific
  // implementation.
  // Concretely, the test expects that classes that aren't instantiated are
  // tree-shaken. While we always have to have the name of the holder, we
  // are not guaranteed to have a reference to the outer class.
  // We very much expect the class for 'B.gee' to exist, since it's instantiated, but
  // future optimization could theoretically get rid of it.
  // Similarly, we currently have source information for the class 'C', because it
  // is used in an 'as' check (where a subclass exists), but future optimizations could
  // remove that class as well.
  // If you see failures in this part of the test, you should consider changing (or
  // removing the check).
  expect_null foo.outer  // The class is tree-shaken.
  gee_holder_id := gee.outer
  expect_not_null gee_holder_id
  b_class_info /ClassInfo := program.class_info_for gee_holder_id
  expect_equals "B" b_class_info.name
  toto_holder_id := toto.outer
  expect_not_null toto_holder_id
  c_class_info /ClassInfo := program.class_info_for toto_holder_id
  expect_equals "C" c_class_info.name
