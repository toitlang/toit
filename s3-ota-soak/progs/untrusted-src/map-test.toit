// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

expect-error name [code]:
  expect-equals
    name
    catch code

main:
  test1
  test2
  test-any-every

test1:
  map := {:}
  expect-equals 0 map.size
  expect-equals 499 (map.get 0 --if-absent=: 499)
  expect-equals 0 map.size

  map[0] = 42
  expect-equals 1 map.size
  expect-equals 42 map[0]
  map[0] = 499
  expect-equals 1 map.size
  expect-equals 499 map[0]
  1000.repeat:
    map.remove 0
    map[0] = it
    expect-equals 1 map.size
    expect-equals it map[0]
  map.remove 0
  1000.repeat:
    map[it] = it
    expect-equals 1 map.size
    expect-equals it map[it]
    map.remove it

  100.repeat: map[it] = it * 2
  map = map.filter: |key value|
    expect-equals key*2 value
    key < 50
  expect-equals 50 map.size
  expect-equals 49*2 map[49]
  expect-equals 999 (map.get 50 --if-absent=: 999)

  map.filter --in-place: |key value| key < 20
  expect-equals 20 map.size
  expect-equals 1*2 map[1]
  expect-equals 999 (map.get 20 --if-absent=: 999)

  counter := 0
  map.do: |key value|
    expect-equals key*2 value
    counter++
  expect-equals 20 counter

  counter = 0
  map.do --reversed: |key value|
    expect-equals key*2 value
    counter++
  expect-equals 20 counter

  sum := 0
  map.do --keys: sum += it
  expect-equals 190 sum

  sum = 0
  map.do --keys --reversed: sum += it
  expect-equals 190 sum

  sum = 0
  map.do --values: sum += it
  expect-equals 190*2 sum

  sum = 0
  map.do --values --reversed: sum += it
  expect-equals 190*2 sum

  expect-equals null (map.get -1)
  expect-equals 3*2 (map.get 3)

  expect-equals 999 (map.get -1 --if-absent=: 999)
  expect-equals null (map.get -1 --if-present=: 999)
  expect-equals 999 (map.get 1 --if-present=: 999)
  expect-equals 999 (map.get -1 --if-absent=(: 999) --if-present=(: 42))
  expect-equals 42 (map.get 1 --if-absent=(: 999) --if-present=(: 42))

  map.update 3: it * 3
  expect-equals 3*2*3 map[3]

  map.update 3
      --if-absent=: throw "should not run"
      : it / 3
  expect-equals 3*2 map[3]

  map.update 499
      --if-absent=: 42
      : throw "should not run"
  expect-equals 42 map[499]

  map.update 5
      --init=: throw "should not run"
      : it * 5
  expect-equals 42 map[499]

  map.update 777
      --init=: 887
      : it + 1
  expect-equals 888 map[777]

  map.update 888 --init=887: it + 1
  expect-equals 888 map[888]

  map.update 999 --if-absent=42: it + 1
  expect-equals 42 map[999]

  map.clear
  map.update 42 --init=(:[42]): it.add 499; it
  map.update 42 --init=(:[43]): it.add 500; it
  map.update 42 --init=(:[44]): it.add 501; it
  map.update 42 --init=(:[45]): it.add 502; it
  expect-list-equals [42, 499, 500, 501, 502] map[42]

  map.clear
  map.update 42 --if-absent=(:[42]): it.add 499; it
  map.update 42 --if-absent=(:[43]): it.add 500; it
  map.update 42 --if-absent=(:[44]): it.add 501; it
  map.update 42 --if-absent=(:[45]): it.add 502; it
  expect-list-equals [42, 500, 501, 502] map[42]

  map.clear
  (map.get 42 --init=(:[42])).add 499
  (map.get 42 --init=(:[42])).add 500
  (map.get 42 --init=(:[42])).add 501
  (map.get 42 --init=(:[42])).add 502
  expect-list-equals [42, 499, 500, 501, 502] map[42]

  map = { 3: 5 }
  key := null
  map.get 499 --if-absent=: key = it
  expect-equals 499 key

  expect-list-equals [3] map.keys
  expect-list-equals [5] map.values

  key = null
  map.update 499 --if-absent=(: key = it): it + 1
  expect-equals 499 key

  expect-list-equals [3, 499] map.keys
  expect-list-equals [5, 499] map.values

  map = {:}
  expect-list-equals [] map.keys
  expect-list-equals [] map.values

  map = {
    "foo": 1,
    "bar": 2,
    "gee": 1,
  }
  expect-list-equals ["foo", "bar", "gee"] map.keys
  expect-list-equals [1, 2, 1] map.values

  cpy := map.copy
  cpy["baz"] = 4
  expect-equals 4 cpy.size
  expect-equals 3 map.size

  result := map.reduce --values: | result value |
    result += value
  expect-equals 4 result

  result = map.reduce --values --initial=0: | result value |
    result += value
  expect-equals 4 result

  result = map.reduce --keys --initial="": | result key |
    result += key
  expect-equals "foobargee" result

  result = map.reduce --keys: | result key |
    result += key
  expect-equals "foobargee" result

  result = map.reduce --initial="": | result key |
    result += key
  expect-equals "foobargee" result

  cpy = map.reduce --initial={:}: | result key value |
    result[key] = value
    result

  expect-list-equals map.keys cpy.keys
  expect-list-equals map.values cpy.values

  one-map := {"foo": 1}

  result = one-map.reduce --values: | result key |
    unreachable
  expect-equals 1 result

  result = one-map.reduce --keys: | result key |
    unreachable
  expect-equals "foo" result

  empty-map := {:}

  expect-error "Not enough elements":
    empty-map.reduce --values: | x y | x + y

  expect-error "Not enough elements":
    empty-map.reduce --keys: | x y | x + y

test2:
  map := {:}
  100.repeat:
    map[it] = it

  counter := 0
  map.do: | key value |
    expect-equals counter key
    expect-equals counter value
    counter++
  map.do --reversed: | key value |
    counter--
    expect-equals counter key
    expect-equals counter value

  map.filter --in-place: | key value |
    if key % 2 == 0:
      false
    else if key % 3 == 0:
      false
    else:
      true

  counter = 0
  map.do: | key value |
    while counter % 2 == 0 or counter % 3 == 0:
      counter++
    expect-equals counter key
    expect-equals counter value
    counter++

  expect-equals 98 counter

  map.do --reversed: | key value |
    counter--
    while counter % 2 == 0 or counter % 3 == 0:
      counter--
    expect-equals counter key
    expect-equals counter value

  expect-equals 1 counter

test-any-every:
  map := {:}
  expect-equals false (map.any: true)
  expect-equals false (map.any --keys: true)
  expect-equals false (map.any --values: true)
  expect-equals true (map.every: false)
  expect-equals true (map.every --keys: false)
  expect-equals true (map.every --values: false)

  map[0] = 42
  expect-equals false (map.any --keys: it == 42)
  expect-equals false (map.any: | k v | k == 42)
  expect-equals false (map.any: | k v | v == 0)
  expect-equals false (map.any --values: it == 0)
  expect-equals true (map.any --keys: it == 0)
  expect-equals true (map.any: | k v | k == 0)
  expect-equals true (map.any: | k v | v == 42)
  expect-equals true (map.any --values: it == 42)

  expect-equals false (map.every --keys: it == 42)
  expect-equals false (map.every: | k v | k == 42)
  expect-equals false (map.every: | k v | v == 0)
  expect-equals false (map.every --values: it == 0)
  expect-equals true (map.every --keys: it == 0)
  expect-equals true (map.every: | k v | k == 0)
  expect-equals true (map.every: | k v | v == 42)
  expect-equals true (map.every --values: it == 42)

  map[1] = 103
  expect-equals false (map.any --keys: it == 42)
  expect-equals false (map.any: | k v | k == 42)
  expect-equals false (map.any: | k v | v == 0)
  expect-equals false (map.any --values: it == 0)
  expect-equals true (map.any --keys: it == 0)
  expect-equals true (map.any: | k v | k == 0)
  expect-equals true (map.any: | k v | v == 42)
  expect-equals true (map.any --values: it == 42)

  expect-equals false (map.every --keys: it == 42)
  expect-equals false (map.every: | k v | k == 42)
  expect-equals false (map.every: | k v | v == 0)
  expect-equals false (map.every --values: it == 0)
  expect-equals false (map.every --keys: it == 0)
  expect-equals false (map.every: | k v | k == 0)
  expect-equals false (map.every: | k v | v == 42)
  expect-equals false (map.every --values: it == 42)

