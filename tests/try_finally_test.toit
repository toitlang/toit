// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

main:
  test_simple_try_finally
  test_return_from_try
  test_throw_from_try
  test_continue_unwinding

test_simple_try_finally:
  x := 0
  try:
    x += 1
  finally:
    x += 2
  expect_equals 3 x

test_return_from_try:
  expect_equals
    1 + 3
    return_from_try[0]
  expect_equals
    42 + 1 + 3
    (return_from_try 42)[0]
  expect_equals
    1 + 3 + 10 + 30
    nested_return_from_try[0]

test_throw_from_try:
  a := List 1
  expect_equals
    a
    catch: throw_from_try a
  expect_equals
    1 + 3
    a[0]

test_continue_unwinding:
  expect_equals 42 a0
  expect_equals
    1
    a1 1
  expect_equals
    2
    a1 2
  expect_equals
    3
    a2 7 4

return_from_try:
  a := List 1
  a[0] = 0
  try:
    a[0] += 1
    return a
    a[0] += 2
  finally:
    a[0] += 3

nested_return_from_try:
  a := List 1
  a[0] = 0
  try:
    a[0] += 1
    try:
      a[0] += 10
      return a
      a[0] += 20
    finally:
      a[0] += 30
    a[0] += 2
  finally:
    a[0] += 3

return_from_try n:
  a := List 1
  a[0] = n
  try:
    a[0] += 1
    return a
    a[0] += 2
  finally:
    a[0] += 3

throw_from_try a:
  a[0] = 0
  try:
    a[0] += 1
    throw a
    a[0] += 2
  finally:
    a[0] += 3

a0:
  exec: return 42
  unreachable

a1 x:
  exec: return x
  unreachable

a2 x y:
  exec: return x - y
  unreachable

exec [block]:
  try: block.call
  finally: // Do nothing.
