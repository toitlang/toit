// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

test0:
  // No local.
  try:
    null
  finally: | in_throw exception |
    expect_not in_throw
    expect_null exception

test1:
  // With local. (shifting the try/finally locals.
  was_in_finally := false
  try:
    null
  finally: | in_throw exception |
    expect_not in_throw
    expect_null exception
    was_in_finally = true
  expect was_in_finally

test2:
  try:
    return 499
  finally: | in_throw exception |
    expect_not in_throw
    expect_null exception

test3 arg:
  try:
    return arg + 1
  finally: | in_throw exception |
    expect_not in_throw
    expect_null exception

was_in_test4 := false
test4b:
  try:
    throw "foo"
  finally: | in_throw exception |
    expect in_throw
    expect_equals "foo" exception.value
    was_in_test4 = true

test4:
  exception := catch: test4b
  expect_equals "foo" exception
  expect was_in_test4

test5:
  was_in_finally := false
  exception := catch:
    try:
      throw "bar"
    finally: | in_throw exception |
      expect in_throw
      expect_equals "bar" exception.value
      was_in_finally = true
  expect was_in_finally
  expect_equals "bar" exception

run [block]: block.call

was_in_test6 := false
test6b:
  run:
    try:
      run:
        return 499
    finally: | in_throw exception |
      expect_not in_throw
      expect_null exception
      was_in_test6 = true
  unreachable

test6:
  expect_equals 499 test6b

was_in_test7 := false
test7b:
  run:
    try:
      run:
        throw "gee"
    finally: | in_throw exception |
      expect in_throw
      expect_equals "gee" exception.value
      was_in_test7 = true

test7:
  exception := catch: test7b
  expect_equals "gee" exception

test8:
  was_in_finally := false
  while true:
    try:
      break
    finally: | in_throw exception |
      expect_not in_throw
      expect_null exception
      was_in_finally = true
  expect was_in_finally

test9:
  was_in_finally := false
  while true:
    run:
      try:
        break
      finally: | in_throw exception |
        expect_not in_throw
        expect_null exception
        was_in_finally = true
  expect was_in_finally

testA:
  try:
    null
  finally: | in_throw/bool exception/Exception_? |
    expect_not in_throw
    expect_null exception

testBb:
  try:
    throw "toto"
  finally: | in_throw/bool exception/Exception_? |
    expect in_throw
    expect_equals "toto" exception.value

testB:
  catch: testBb

testC:
  try:
    null
  finally: | _ _ |

main:
  test0
  test1
  expect_equals 499 test2
  expect_equals 499 (test3 498)
  test4
  test5
  test6
  test7
  test8
  test9
  testA
  testB
  testC
