// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.snapshot

main args:
  snapshot_path := args[0]
  snapshot := SnapshotBundle.from_file snapshot_path
  program := snapshot.decode

  not_methods := ["global_field", "global_lazy_field="]

  needles := {
    "ClassA.field_a",
    "ClassA.field_a=",
    "ClassA.final_field",
    "ClassA.final_field=",
    "ClassA.method_a",
    "ClassA.method_b",
    "ClassB.method_b",
    "ClassA.constructor",
    "ClassB.constructor",
    "ClassA.static_method",
    "ClassA.named",
    "global_method",
    "global_lazy_field",
    "Nested.block",
    "Nested.lambda",
  }
  needles.add_all not_methods

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
        outer_name = program.class_name_for method.outer
      else if method.type == MethodInfo.TOP_LEVEL_TYPE:
        outer_name = method.holder_name or ""
      if per_method_name[method.name].contains outer_name:
        prefix := outer_name == "" ? "" : "$(outer_name)."
        (found_methods.get "$(prefix)$method.name" --init=:[]).add method

  // Global fields are directly accessed and don't need a getter.
  not_methods.do:
    expect_not (found_methods.contains it)
    needles.remove it

  // Check that all other needles are found.
  needles.do:
    expect (found_methods.contains it)

  // Do some spot checks.
  method_bs := found_methods["ClassA.method_b"]
  expect_equals 2 method_bs.size
  method1 := program.method_from_absolute_bci method_bs[0].id
  method2 := program.method_from_absolute_bci method_bs[1].id
  // Arities include the implicit `this` parameter.
  expect (method1.arity == 2 and method2.arity == 3 or
      method1.arity == 3 and method2.arity == 2)

  lazy_fields := found_methods["global_lazy_field"]
  expect_equals 1 lazy_fields.size
  info1 := lazy_fields[0]
  expect_equals MethodInfo.GLOBAL_TYPE info1.type

  field_getter_id := found_methods["ClassA.field_a"].first.id
  field_getter := program.method_from_absolute_bci field_getter_id
  expect field_getter.is_field_accessor
  field_setter_id := found_methods["ClassA.field_a="].first.id
  field_setter := program.method_from_absolute_bci field_setter_id
  expect field_setter.is_field_accessor

  final_field_getter_id := found_methods["ClassA.final_field"].first.id
  final_field_getter := program.method_from_absolute_bci final_field_getter_id
  expect final_field_getter.is_field_accessor
  final_field_setter_id := found_methods["ClassA.final_field="].first.id
  final_field_setter := program.method_from_absolute_bci final_field_setter_id
  // The final field setter is not considered an accessor.
  expect_not final_field_setter.is_field_accessor

  method_a_id := found_methods["ClassA.method_a"].first.id
  method_a := program.method_from_absolute_bci method_a_id
  expect_not method_a.is_field_accessor
  expect method_a.is_normal_method

  // Find the block and lambda from the test.
  outer_block_id := found_methods["Nested.block"].first.id
  outer_lambda_id := found_methods["Nested.lambda"].first.id
  block_info := null
  lambda_info := null
  program.do --method_infos: | method/MethodInfo |
    if method.type == MethodInfo.BLOCK_TYPE and method.outer == outer_block_id:
      block_info = method
    else if method.type == MethodInfo.LAMBDA_TYPE and method.outer == outer_lambda_id:
      lambda_info = method
  expect_not_null block_info
  expect_not_null lambda_info

  block_method := program.method_from_absolute_bci block_info.id
  expect block_method.is_block
  lambda_method := program.method_from_absolute_bci lambda_info.id
  expect lambda_method.is_lambda
