// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.snapshot

main args:
  snapshot-path := args[0]
  snapshot := SnapshotBundle.from-file snapshot-path
  program := snapshot.decode

  not-methods := ["global-field", "global-lazy-field="]

  needles := {
    "ClassA.field-a",
    "ClassA.field-a=",
    "ClassA.final-field",
    "ClassA.final-field=",
    "ClassA.method-a",
    "ClassA.method-b",
    "ClassB.method-b",
    "ClassA.constructor",
    "ClassB.constructor",
    "ClassA.static-method",
    "ClassA.named",
    "global-method",
    "global-lazy-field",
    "Nested.block",
    "Nested.lambda",
  }
  needles.add-all not-methods

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
        outer-name = program.class-name-for method.outer
      else if method.type == MethodInfo.TOP-LEVEL-TYPE:
        outer-name = method.holder-name or ""
      if per-method-name[method.name].contains outer-name:
        prefix := outer-name == "" ? "" : "$(outer-name)."
        (found-methods.get "$(prefix)$method.name" --init=:[]).add method

  // Global fields are directly accessed and don't need a getter.
  not-methods.do:
    expect-not (found-methods.contains it)
    needles.remove it

  // Check that all other needles are found.
  needles.do:
    expect (found-methods.contains it)

  // Do some spot checks.
  method-bs := found-methods["ClassA.method-b"]
  expect-equals 2 method-bs.size
  method1 := program.method-from-absolute-bci method-bs[0].absolute-entry-bci
  method2 := program.method-from-absolute-bci method-bs[1].absolute-entry-bci
  // Arities include the implicit `this` parameter.
  expect (method1.arity == 2 and method2.arity == 3 or
      method1.arity == 3 and method2.arity == 2)

  lazy-fields := found-methods["global-lazy-field"]
  expect-equals 1 lazy-fields.size
  info1 := lazy-fields[0]
  expect-equals MethodInfo.GLOBAL-TYPE info1.type

  field-getter-entry := found-methods["ClassA.field-a"].first.absolute-entry-bci
  field-getter := program.method-from-absolute-bci field-getter-entry
  expect field-getter.is-field-accessor
  field-setter-entry := found-methods["ClassA.field-a="].first.absolute-entry-bci
  field-setter := program.method-from-absolute-bci field-setter-entry
  expect field-setter.is-field-accessor

  final-field-getter-entry := found-methods["ClassA.final-field"].first.absolute-entry-bci
  final-field-getter := program.method-from-absolute-bci final-field-getter-entry
  expect final-field-getter.is-field-accessor
  final-field-setter-entry := found-methods["ClassA.final-field="].first.absolute-entry-bci
  final-field-setter := program.method-from-absolute-bci final-field-setter-entry
  // The final field setter is not considered an accessor.
  expect-not final-field-setter.is-field-accessor

  method-a-entry := found-methods["ClassA.method-a"].first.absolute-entry-bci
  method-a := program.method-from-absolute-bci method-a-entry
  expect-not method-a.is-field-accessor
  expect method-a.is-normal-method

  // Find the block and lambda from the test.
  outer-block-id := found-methods["Nested.block"].first.id
  outer-lambda-id := found-methods["Nested.lambda"].first.id
  block-info := null
  lambda-info := null
  program.do --method-infos: | method/MethodInfo |
    if method.type == MethodInfo.BLOCK-TYPE and method.outer == outer-block-id:
      block-info = method
    else if method.type == MethodInfo.LAMBDA-TYPE and method.outer == outer-lambda-id:
      lambda-info = method
  expect-not-null block-info
  expect-not-null lambda-info

  block-method := program.method-from-absolute-bci block-info.absolute-entry-bci
  expect block-method.is-block
  lambda-method := program.method-from-absolute-bci lambda-info.absolute-entry-bci
  expect lambda-method.is-lambda
