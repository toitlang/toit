// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.snapshot

main args:
  snapshot-path := args[0]
  snapshot := SnapshotBundle.from-file snapshot-path
  program := snapshot.decode

  needles := {
    "A.foo",
    "bar",
    "B.gee",
    "C.toto",
  }

  per-method-name := {:}
  needles.do:
    method-name := null
    outer-name := null
    if it.contains ".":
      parts := it.split "."
      method-name = parts[1]
      outer-name = parts[0]
    else:
      method-name = it
      outer-name = ""
    (per-method-name.get method-name --init=:{}).add outer-name

  found-methods := {:}
  program.do --method-infos: | method/MethodInfo |
    if per-method-name.contains method.name:
      outer-name := ""
      if method.type == MethodInfo.INSTANCE-TYPE:
        outer-name = (program.class-name-for method.outer)
      else if method.type == MethodInfo.TOP-LEVEL-TYPE:
        outer-name = method.holder-name or ""
      if per-method-name[method.name].contains outer-name:
        prefix := outer-name == "" ? "" : "$(outer-name)."
        (found-methods.get "$(prefix)$method.name" --init=:[]).add method

  // Check that all needles are found.
  needles.do:
    expect (found-methods.contains it)

  // Do some spot checks.
  foo /MethodInfo := found-methods["A.foo"][0]
  bar /MethodInfo := found-methods["bar"][0]
  gee /MethodInfo := found-methods["B.gee"][0]
  toto /MethodInfo := found-methods["C.toto"][0]

  // The following checks are checking the correctness of
  // our source mapping.
  expect-equals "A" foo.holder-name
  expect-null bar.holder-name
  expect-equals "B" gee.holder-name
  expect-equals "C" toto.holder-name
  expect-null bar.outer  // Bar doesn't have an outer.

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
  expect-null foo.outer  // The class is tree-shaken.
  gee-holder-id := gee.outer
  expect-not-null gee-holder-id
  b-class-info /ClassInfo := program.class-info-for gee-holder-id
  expect-equals "B" b-class-info.name
  toto-holder-id := toto.outer
  expect-not-null toto-holder-id
  c-class-info /ClassInfo := program.class-info-for toto-holder-id
  expect-equals "C" c-class-info.name
