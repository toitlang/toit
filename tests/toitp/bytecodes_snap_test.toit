// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.snapshot

find_bytecode_test_method program/Program -> MethodInfo:
  program.do --method_infos: | method/MethodInfo |
    if method.name == "bytecode_test" and method.type == MethodInfo.TOP_LEVEL_TYPE:
      return method
  throw "not found"

main args:
  snapshot_path := args[0]
  snapshot := SnapshotBundle.from_file snapshot_path
  program := snapshot.decode

  test_info := find_bytecode_test_method program
  test_method := program.method_from_absolute_bci test_info.id

  allocate_count := 0
  static_call_count := 0
  virtual_call_count := 0
  global_store_count := 0
  is_class_count := 0
  as_class_count := 0
  is_interface_count := 0
  as_interface_count := 0
  as_local_count := 0
  test_method.do_bytecodes:
    if it.name == "INVOKE_STATIC":
      static_call_count++
    else if it.name == "ALLOCATE":
      allocate_count++
    else if it.name == "INVOKE_VIRTUAL":
      virtual_call_count++
    else if it.name == "STORE_GLOBAL_VAR":
      global_store_count++
    else if it.name == "STORE_GLOBAL_VAR":
      global_store_count++
    else if it.name == "IS_CLASS":
      is_class_count++
    else if it.name == "AS_CLASS":
      as_class_count++
    else if it.name == "IS_INTERFACE":
      is_interface_count++
    else if it.name == "AS_INTERFACE":
      as_interface_count++
    else if it.name == "AS_LOCAL":
      as_local_count++
  expect_equals 2 allocate_count
  expect_equals 7 static_call_count // 2 constructor calls, 1 static call, 4 confuse calls.
  expect_equals 2 virtual_call_count
  expect_equals 1 global_store_count
  expect_equals 1 is_class_count
  expect_equals 1 as_class_count
  expect_equals 1 is_interface_count
  expect_equals 1 as_interface_count
  expect_equals 1 as_local_count
