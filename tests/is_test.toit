// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:

class B extends A:

class C extends B:

class D extends C:

class E:

main:
  expect A is A
  expect B is A
  expect C is A
  expect D is A
  expect B is B
  expect C is B
  expect D is B
  expect D is C
  expect D is D

  expect_equals false A is B
  expect_equals false A is E
  expect_equals false E is A
  expect_equals false E is D

  expect 499 is int
  expect "foo" is string
  expect_equals false "foo" is int
  expect_equals false 499 is string

  expect null is Object
  expect 499 is Object
  expect A is Object
  expect "foo" is Object

  expect_equals false null is A

  expect null is Null_
  expect_equals false "foo" is Null_
  expect_equals false A is Null_

  expect_equals false A is not A
  expect_equals false B is not A
  expect_equals false C is not A
  expect_equals false D is not A
  expect_equals false B is not B
  expect_equals false C is not B
  expect_equals false D is not B
  expect_equals false D is not C
  expect_equals false D is not D

  expect A is not B
  expect A is not E
  expect E is not A
  expect E is not D

  expect_equals false 499 is not int
  expect_equals false "foo" is not string
  expect "foo" is not int
  expect 499 is not string

  expect_equals false null is not Object
  expect_equals false 499 is not Object
  expect_equals false A is not Object
  expect_equals false "foo" is not Object

  expect_equals false null is not Null_
  expect "foo" is not Null_
  expect A is not Null_

  expect null is not A

  expect 4 is any

  expect 4 is not A
  expect 4 is /* comment */ not A

  local := 4
  lambda := (:: local++)
  expect lambda.call is int
  expect local is int
