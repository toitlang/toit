// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.snapshot

find-bytecode-test-method program/Program -> MethodInfo:
  program.do --method-infos: | method/MethodInfo |
    if method.name == "bytecode-test" and method.type == MethodInfo.TOP-LEVEL-TYPE:
      return method
  throw "not found"

main args:
  snapshot-path := args[0]
  snapshot := SnapshotBundle.from-file snapshot-path
  program := snapshot.decode

  test-info := find-bytecode-test-method program
  test-method := program.method-from-absolute-bci test-info.absolute-entry-bci

  allocate-count := 0
  static-call-count := 0
  virtual-call-count := 0
  global-store-count := 0
  is-class-count := 0
  as-class-count := 0
  is-interface-count := 0
  as-interface-count := 0
  as-local-count := 0
  test-method.do-bytecodes:
    if it.name == "INVOKE_STATIC":
      static-call-count++
    else if it.name == "ALLOCATE":
      allocate-count++
    else if it.name == "INVOKE_VIRTUAL":
      virtual-call-count++
    else if it.name == "STORE_GLOBAL_VAR":
      global-store-count++
    else if it.name == "STORE_GLOBAL_VAR":
      global-store-count++
    else if it.name == "IS_CLASS":
      is-class-count++
    else if it.name == "AS_CLASS":
      as-class-count++
    else if it.name == "IS_INTERFACE":
      is-interface-count++
    else if it.name == "AS_INTERFACE":
      as-interface-count++
    else if it.name == "AS_LOCAL":
      as-local-count++
  expect-equals 2 allocate-count
  expect-equals 2 virtual-call-count
  expect-equals 1 global-store-count
  expect-equals 1 is-class-count
  expect-equals 1 as-class-count
  expect-equals 1 is-interface-count
  expect-equals 1 as-interface-count
  expect-equals 0 as-local-count

  // Static calls: 2 constructor calls, 1 static call,
  // 2 de-virtualized calls, and 6 confuse calls.
  expect-equals 11 static-call-count
