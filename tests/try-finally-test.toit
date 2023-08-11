// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-simple-try-finally
  test-return-from-try
  test-throw-from-try
  test-continue-unwinding

test-simple-try-finally:
  x := 0
  try:
    x += 1
  finally:
    x += 2
  expect-equals 3 x

test-return-from-try:
  expect-equals
    1 + 3
    return-from-try[0]
  expect-equals
    42 + 1 + 3
    (return-from-try 42)[0]
  expect-equals
    1 + 3 + 10 + 30
    nested-return-from-try[0]

test-throw-from-try:
  a := List 1
  expect-equals
    a
    catch: throw-from-try a
  expect-equals
    1 + 3
    a[0]

test-continue-unwinding:
  expect-equals 42 a0
  expect-equals
    1
    a1 1
  expect-equals
    2
    a1 2
  expect-equals
    3
    a2 7 4

return-from-try:
  a := List 1
  a[0] = 0
  try:
    a[0] += 1
    return a
    a[0] += 2
  finally:
    a[0] += 3

nested-return-from-try:
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

return-from-try n:
  a := List 1
  a[0] = n
  try:
    a[0] += 1
    return a
    a[0] += 2
  finally:
    a[0] += 3

throw-from-try a:
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
