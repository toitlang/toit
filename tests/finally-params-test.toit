// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

test0:
  // No local.
  try:
    null
  finally: | in-throw exception |
    expect-not in-throw
    expect-null exception

test1:
  // With local (shifting the try/finally locals).
  was-in-finally := false
  try:
    null
  finally: | in-throw exception |
    expect-not in-throw
    expect-null exception
    was-in-finally = true
  expect was-in-finally

test2:
  try:
    return 499
  finally: | in-throw exception |
    expect-not in-throw
    expect-null exception

test3 arg:
  try:
    return arg + 1
  finally: | in-throw exception |
    expect-not in-throw
    expect-null exception

was-in-test4 := false
test4b:
  try:
    throw "foo"
  finally: | in-throw exception |
    expect in-throw
    expect-equals "foo" exception.value
    was-in-test4 = true

test4:
  exception := catch: test4b
  expect-equals "foo" exception
  expect was-in-test4

test5:
  was-in-finally := false
  exception := catch:
    try:
      throw "bar"
    finally: | in-throw exception |
      expect in-throw
      expect-equals "bar" exception.value
      was-in-finally = true
  expect was-in-finally
  expect-equals "bar" exception

run [block]: block.call

was-in-test6 := false
test6b:
  run:
    try:
      run:
        return 499
    finally: | in-throw exception |
      expect-not in-throw
      expect-null exception
      was-in-test6 = true
  unreachable

test6:
  expect-equals 499 test6b

was-in-test7 := false
test7b:
  run:
    try:
      run:
        throw "gee"
    finally: | in-throw exception |
      expect in-throw
      expect-equals "gee" exception.value
      was-in-test7 = true

test7:
  exception := catch: test7b
  expect-equals "gee" exception

test8:
  was-in-finally := false
  while true:
    try:
      break
    finally: | in-throw exception |
      expect-not in-throw
      expect-null exception
      was-in-finally = true
  expect was-in-finally

test9:
  was-in-finally := false
  while true:
    run:
      try:
        break
      finally: | in-throw exception |
        expect-not in-throw
        expect-null exception
        was-in-finally = true
  expect was-in-finally

testA:
  try:
    null
  finally: | in-throw/bool exception/Exception_? |
    expect-not in-throw
    expect-null exception

testBb:
  try:
    throw "toto"
  finally: | in-throw/bool exception/Exception_? |
    expect in-throw
    expect-equals "toto" exception.value

testB:
  catch: testBb

testC:
  try:
    null
  finally: | _ _ |

main:
  test0
  test1
  expect-equals 499 test2
  expect-equals 499 (test3 498)
  test4
  test5
  test6
  test7
  test8
  test9
  testA
  testB
  testC
