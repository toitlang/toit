// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *
import host.os

main:
  // The testing framework provides the "TOIT_TEST_ENV_ENTRY" env entry,
  // so we can test it here.
  env_key := "TOIT_TEST_ENV_ENTRY"
  env_value := "TOIT_TEST_ENV_VALUE"
  expect_equals env_value os.env[env_key]
  expect_equals env_value (os.env.get env_key)
  expect (os.env.contains env_key)

  non_existing := "NoN exIstIng KeY"
  expect_null (os.env.get non_existing)
  expect_throw "ENV NOT FOUND": os.env[non_existing]
  expect_not (os.env.contains non_existing)
