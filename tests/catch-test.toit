// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  exception := null

  exception = catch: 42
  expect-null exception
  exception = catch: throw "dog"
  expect-equals "dog" exception

  exception = catch:
    nested := catch --unwind: throw "cat"
    expect false --message="should not reach here"
  expect-equals "cat" exception

  exception = catch:
    nested := catch --unwind: throw "fish"
    expect false --message="should not reach here"
  expect-equals "fish" exception

  exception = catch
    --unwind=:
      expect-equals "lemur" it
      false
    :
      throw "lemur"
      expect false --message="should not reach here"
  expect-equals "lemur" exception

  exception = catch
    --unwind=: | e trace |
      expect-equals "pig" e
      expect-not-null trace
      false
    :
      throw "pig"
      expect false --message="should not reach here"
  expect-equals "pig" exception

  exception = catch:
    nested := catch
      --unwind=:
        expect-equals "horse" it
        true
      :
        throw "horse"
    expect false --message="should not reach here"
  expect-equals "horse" exception

  exception = catch:
    nested := catch
      --unwind=: | e trace |
        expect-equals "bird" e
        expect-not-null trace
        true
      :
        throw "bird"
    expect false --message="should not reach here"
  expect-equals "bird" exception

  // TODO(kasper): Find a good way to test stack traces.
