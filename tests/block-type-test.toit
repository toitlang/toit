// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

filter list/List [predicate int -> bool] -> List:
  result := []
  list.do: if predicate.call it: result.add it
  return result

each list/List [block any -> none] -> none:
  list.do: block.call it

two-params [b int string -> int] -> int:
  return (b.call 1 "a") + (b.call 2 "b")

no-params [b -> int] -> int:
  return b.call

named --x/int [--b int -> int] -> int:
  return b.call x

nullable-param [b int? -> none] -> none:
  b.call 1
  b.call null

// A block that completes with a `none` expression yields null.
nullable-return [b -> int?] -> int?:
  return b.call

// Documentary: no arguments, result passed through unchecked.
no-params-any [b -> any] -> any:
  return b.call

raw [b] -> any:
  return b.call 1 2

pass-through list/List [b int -> bool] -> List:
  return filter list b

no-return-type [b int]:
  return b.call 42

returns-none [b int -> none] -> none:
  b.call 1

// Raw blocks stay untyped in both directions.
forward-raw list/List [b] -> List:
  return filter list b

forward-typed [b int -> bool] -> any:
  return raw b

// No checks for `any` parameters and `any`/`none` returns.
pass-anything x/any [b any -> none] -> none:
  b.call x

yield-anything list/List [b int -> any] -> any:
  return b.call list[0]

// Runtime checks: the static types don't reveal the mismatch.
call-with x/any [b int -> none] -> none:
  b.call x

yield-any list/List [b int -> bool] -> none:
  list.do: b.call it

returns-early list/List -> int:
  filter list: return it
  return -1

// A `while true` without `break` never completes; the block leaves with
// `continue`.
loops-until list/List -> int:
  i := 0
  return no-params:
    while true:
      if list[i++] > 1: continue.no-params i

main:
  expect-equals [2] (filter [1, 2, 3]: it % 2 == 0)
  expect-equals [1, 3] (filter [1, 2, 3]: |x/int| x % 2 == 1)
  expect-equals [1, 3] (filter [1, 2, 3]: |x| x % 2 == 1)
  // Blocks with fewer parameters than the type are fine.
  expect-equals [1, 2, 3] (filter [1, 2, 3]: true)
  each [1, 2]: it + 1  // The result is ignored.
  each [1, 2]: null
  expect-equals 3 (two-params: |x/int y/string| x)
  expect-equals 3 (two-params: |x| x)
  expect-equals 3 (two-params: it)
  expect-equals 7 (no-params: 7)
  expect-equals 7 (no-params-any: 7)
  expect-equals 6 (named --x=3 --b=: it * 2)
  nullable-param: null
  nullable-param: |x/int?| x
  expect-null (nullable-return: print "no value")
  expect-equals 1 (nullable-return: 1)

  // Compatibility with untyped code: error blocks with side effects only,
  // numeric compare results, and stringify blocks returning non-strings.
  expect-null (int.parse "x" --if-error=: print "bad int")
  expect-equals [1.5, 2] ([2, 1.5].sort: |a b| a - b)
  expect-equals "1, 2" ([1, 2].join ", ": it)
  expect-equals "str" (no-params-any: "str")
  expect-null (no-params-any: null)
  expect-equals 1 (raw: it)
  expect-equals [3] (pass-through [1, 2, 3]: it > 2)
  expect-equals 42 (no-return-type: it)
  returns-none: it
  returns-none: print it

  // Blocks that never complete fit any return type.
  expect-equals [] (filter []: throw "unreachable")
  diverging := catch: filter [1]: throw "boom"
  expect-equals "boom" diverging
  expect-equals 1 (returns-early [1, 2])
  expect-equals 2 (loops-until [1, 2, 3])
  while true:
    filter [1]: break
    break

  // Block locals get the type of their block.
  b := : |x/int| x > 1
  expect-equals [2, 3] (filter [1, 2, 3] b)
  expect (b.call 2)

  // Static checks inside the callee: `predicate.call` yields a bool.
  x/bool := (filter [1]: true).size == 1
  expect x

  // A raw block is accepted by a typed parameter without a static check,
  // but the typed callee still checks at runtime.
  expect-equals [1, 3] (forward-raw [1, 2, 3]: it % 2 == 1)
  e := catch: forward-raw [1, 2, 3]: "not a bool"
  expect-equals "AS_CHECK_FAILED" e
  // A typed block is accepted by a raw parameter; the raw call is unchecked.
  expect (forward-typed: it > 0)
  // The raw call passes 2 arguments to a 1-parameter block.
  expect (forward-typed: |x/int| x > 0)

  // `any` positions are unchecked: anything goes through.
  pass-anything "str": it
  pass-anything null: it
  expect-equals "str" (yield-anything [1]: "str")
  expect-null (yield-anything [1]: null)

  // The arguments passed by the callee are checked at runtime.
  e = catch: call-with "str": it
  expect-equals "AS_CHECK_FAILED" e
  call-with 1: it

  // The value the block yields is checked at runtime.
  e = catch: yield-any [1]: it
  expect-equals "AS_CHECK_FAILED" e
  yield-any [1]: it == 1
