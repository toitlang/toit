// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.os

main:
  // The testing framework provides the "TOIT_TEST_ENV_ENTRY" env entry,
  // so we can test it here.
  env-key := "TOIT_TEST_ENV_ENTRY"
  env-value := "TOIT_TEST_ENV_VALUE"
  expect-equals env-value os.env[env-key]
  expect-equals env-value (os.env.get env-key)
  expect (os.env.contains env-key)

  non-existing := "NoN exIstIng KeY"
  expect-null (os.env.get non-existing)
  expect-throw "ENV NOT FOUND": os.env[non-existing]
  expect-not (os.env.contains non-existing)
