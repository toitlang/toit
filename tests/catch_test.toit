// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  exception := null

  exception = catch: 42
  expect_null exception
  exception = catch: throw "dog"
  expect_equals "dog" exception

  exception = catch:
    nested := catch --unwind: throw "cat"
    expect false --message="should not reach here"
  expect_equals "cat" exception

  exception = catch:
    nested := catch --unwind: throw "fish"
    expect false --message="should not reach here"
  expect_equals "fish" exception

  exception = catch
    --unwind=:
      expect_equals "lemur" it
      false
    :
      throw "lemur"
      expect false --message="should not reach here"
  expect_equals "lemur" exception

  exception = catch
    --unwind=: | e trace |
      expect_equals "pig" e
      expect_not_null trace
      false
    :
      throw "pig"
      expect false --message="should not reach here"
  expect_equals "pig" exception

  exception = catch:
    nested := catch
      --unwind=:
        expect_equals "horse" it
        true
      :
        throw "horse"
    expect false --message="should not reach here"
  expect_equals "horse" exception

  exception = catch:
    nested := catch
      --unwind=: | e trace |
        expect_equals "bird" e
        expect_not_null trace
        true
      :
        throw "bird"
    expect false --message="should not reach here"
  expect_equals "bird" exception

  // TODO(kasper): Find a good way to test stack traces.
