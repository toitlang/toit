// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

expect_error name [code]:
  expect_equals
    name
    catch code

main:
  test1
  test2

test1:
  map := {:}
  expect_equals 0 map.size
  expect_equals 499 (map.get 0 --if_absent=: 499)
  expect_equals 0 map.size

  map[0] = 42
  expect_equals 1 map.size
  expect_equals 42 map[0]
  map[0] = 499
  expect_equals 1 map.size
  expect_equals 499 map[0]
  1000.repeat:
    map.remove 0
    map[0] = it
    expect_equals 1 map.size
    expect_equals it map[0]
  map.remove 0
  1000.repeat:
    map[it] = it
    expect_equals 1 map.size
    expect_equals it map[it]
    map.remove it

  100.repeat: map[it] = it * 2
  map = map.filter: |key value|
    expect_equals key*2 value
    key < 50
  expect_equals 50 map.size
  expect_equals 49*2 map[49]
  expect_equals 999 (map.get 50 --if_absent=: 999)

  map.filter --in_place: |key value| key < 20
  expect_equals 20 map.size
  expect_equals 1*2 map[1]
  expect_equals 999 (map.get 20 --if_absent=: 999)

  counter := 0
  map.do: |key value|
    expect_equals key*2 value
    counter++
  expect_equals 20 counter

  counter = 0
  map.do --reversed: |key value|
    expect_equals key*2 value
    counter++
  expect_equals 20 counter

  sum := 0
  map.do --keys: sum += it
  expect_equals 190 sum

  sum = 0
  map.do --keys --reversed: sum += it
  expect_equals 190 sum

  sum = 0
  map.do --values: sum += it
  expect_equals 190*2 sum

  sum = 0
  map.do --values --reversed: sum += it
  expect_equals 190*2 sum

  expect_equals null (map.get -1)
  expect_equals 3*2 (map.get 3)

  expect_equals 999 (map.get -1 --if_absent=: 999)
  expect_equals null (map.get -1 --if_present=: 999)
  expect_equals 999 (map.get 1 --if_present=: 999)
  expect_equals 999 (map.get -1 --if_absent=(: 999) --if_present=(: 42))
  expect_equals 42 (map.get 1 --if_absent=(: 999) --if_present=(: 42))

  map.update 3: it * 3
  expect_equals 3*2*3 map[3]

  map.update 3
      --if_absent=: throw "should not run"
      : it / 3
  expect_equals 3*2 map[3]

  map.update 499
      --if_absent=: 42
      : throw "should not run"
  expect_equals 42 map[499]

  map.update 5
      --init=: throw "should not run"
      : it * 5
  expect_equals 42 map[499]

  map.update 777
      --init=: 887
      : it + 1
  expect_equals 888 map[777]

  map.update 888 --init=887: it + 1
  expect_equals 888 map[888]

  map.update 999 --if_absent=42: it + 1
  expect_equals 42 map[999]

  map.clear
  map.update 42 --init=(:[42]): it.add 499; it
  map.update 42 --init=(:[43]): it.add 500; it
  map.update 42 --init=(:[44]): it.add 501; it
  map.update 42 --init=(:[45]): it.add 502; it
  expect_list_equals [42, 499, 500, 501, 502] map[42]

  map.clear
  map.update 42 --if_absent=(:[42]): it.add 499; it
  map.update 42 --if_absent=(:[43]): it.add 500; it
  map.update 42 --if_absent=(:[44]): it.add 501; it
  map.update 42 --if_absent=(:[45]): it.add 502; it
  expect_list_equals [42, 500, 501, 502] map[42]

  map.clear
  (map.get 42 --init=(:[42])).add 499
  (map.get 42 --init=(:[42])).add 500
  (map.get 42 --init=(:[42])).add 501
  (map.get 42 --init=(:[42])).add 502
  expect_list_equals [42, 499, 500, 501, 502] map[42]

  map = { 3: 5 }
  key := null
  map.get 499 --if_absent=: key = it
  expect_equals 499 key

  expect_list_equals [3] map.keys
  expect_list_equals [5] map.values

  key = null
  map.update 499 --if_absent=(: key = it): it + 1
  expect_equals 499 key

  expect_list_equals [3, 499] map.keys
  expect_list_equals [5, 499] map.values

  map = {:}
  expect_list_equals [] map.keys
  expect_list_equals [] map.values

  map = {
    "foo": 1,
    "bar": 2,
    "gee": 1,
  }
  expect_list_equals ["foo", "bar", "gee"] map.keys
  expect_list_equals [1, 2, 1] map.values

  cpy := map.copy
  cpy["baz"] = 4
  expect_equals 4 cpy.size
  expect_equals 3 map.size

  result := map.reduce --values: | result value |
    result += value
  expect_equals 4 result

  result = map.reduce --values --initial=0: | result value |
    result += value
  expect_equals 4 result

  result = map.reduce --keys --initial="": | result key |
    result += key
  expect_equals "foobargee" result

  result = map.reduce --keys: | result key |
    result += key
  expect_equals "foobargee" result

  result = map.reduce --initial="": | result key |
    result += key
  expect_equals "foobargee" result

  cpy = map.reduce --initial={:}: | result key value |
    result[key] = value
    result

  expect_list_equals map.keys cpy.keys
  expect_list_equals map.values cpy.values

  one_map := {"foo": 1}

  result = one_map.reduce --values: | result key |
    unreachable
  expect_equals 1 result

  result = one_map.reduce --keys: | result key |
    unreachable
  expect_equals "foo" result

  empty_map := {:}

  expect_error "Bad Argument":
    map.reduce --values=false: | x y | x + y

  expect_error "Not enough elements":
    empty_map.reduce --values: | x y | x + y

  expect_error "Bad Argument":
    map.reduce --keys=false: | x y | x + y

  expect_error "Not enough elements":
    empty_map.reduce --keys: | x y | x + y

test2:
  map := {:}
  100.repeat:
    map[it] = it

  counter := 0
  map.do: | key value |
    expect_equals counter key
    expect_equals counter value
    counter++
  map.do --reversed: | key value |
    counter--
    expect_equals counter key
    expect_equals counter value

  map.filter --in_place: | key value |
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
    expect_equals counter key
    expect_equals counter value
    counter++

  expect_equals 98 counter

  map.do --reversed: | key value |
    counter--
    while counter % 2 == 0 or counter % 3 == 0:
      counter--
    expect_equals counter key
    expect_equals counter value

  expect_equals 1 counter
