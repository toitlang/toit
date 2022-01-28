// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.pipe
import expect show *
import encoding.base64 as base64
import encoding.json as json
import ...tools.snapshot

class Tester:
  program   / Program ::= ?
  snapshots / Map     ::= ?

  constructor .program .snapshots:

  test name [block]:
    snap := snapshots[name]
    decoder := ObjectSnapshot snap program
    val := decoder.decode
    block.call val

expect_is_instance_of o class_name program/Program:
  expect o is ToitInstance
  name := program.class_name_for o.class_id
  expect_equals class_name name

main args:
  toitc := args[0]
  test_dir := args[1]
  input_snap := args[2]

  program_snapshot := SnapshotBundle.from_file input_snap
  program := program_snapshot.decode

  base64_response := pipe.backticks toitc input_snap "--serialize"
  base64_response = base64_response.trim

  object_snaps := json.decode (base64.decode base64_response)
  object_snaps.map --in_place: |key val| base64.decode val

  tester := Tester program object_snaps
  tester.test "smi":
    expect it is ToitInteger
    expect_equals 499 (it as ToitInteger).value

  tester.test "neg_smi":
    expect it is ToitInteger
    expect_equals -499 (it as ToitInteger).value

  tester.test "int64":
    expect it is ToitInteger
    expect_equals 0x7FFF_FFFF_FFFF_FFFF (it as ToitInteger).value

  tester.test "int48":
    expect it is ToitInteger
    expect_equals 0xFFFF_FFFF_FFFF (it as ToitInteger).value

  tester.test "null":
    expect it is ToitOddball
    expect_equals "Null_" (program.class_name_for it.class_id)

  tester.test "true":
    expect it is ToitOddball
    expect_equals "True_" (program.class_name_for it.class_id)

  tester.test "false":
    expect it is ToitOddball
    expect_equals "False_" (program.class_name_for it.class_id)

  tester.test "A":
    expect_is_instance_of it "A" program
    expect_equals 1 it.fields.size
    expect it.fields[0] is ToitInteger
    expect_equals 499 (it.fields[0] as ToitInteger).value

  tester.test "B":
    expect_is_instance_of it "B" program
    expect_equals 2 it.fields.size
    expect it.fields[0] is ToitInteger
    expect_equals 42 (it.fields[0] as ToitInteger).value
    expect_equals it.fields[1] it

  tester.test "lambda":
    expect_is_instance_of it "Lambda" program
    expect_equals 2 it.fields.size
    method_field := it.fields[0]
    arguments_field := it.fields[1]
    expect method_field is ToitInteger
    method_id := (method_field as ToitInteger).value
    lambda /MethodInfo := program.method_info_for method_id
    expect_equals MethodInfo.LAMBDA_TYPE lambda.type
