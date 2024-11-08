// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test-default-true --x
  test-default-true --x=false
  test-default-true --x=true
  test-default-true --no-x
  test-default-true --x=null

  test-default-false --x
  test-default-false --x=false
  test-default-false --x=true
  test-default-false --no-x
  test-default-false --x=null

  test-non-default --x
  test-non-default --x=true
  test-non-default --no-x
  test-non-default --x=false

  test-non-default-non-literal --x
  test-non-default-non-literal --x=true
  test-non-default-non-literal --no-x
  test-non-default-non-literal --x=false

test-default-true --x/bool=true:
  return x

test-default-false --x/bool=false:
  return x

test-non-default --x/bool=true:
  return x

test-non-default-non-literal --x/bool=gettrue:
  return x

gettrue:
  return true
