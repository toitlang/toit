// Copyright (C) 2023 Toitware ApS.
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

  test-only-true
  test-only-true --x
  test-only-true --x=true
  test-only-true --x=null

  test-only-false
  test-only-false --no-x
  test-only-false --x=false
  test-only-false --x=null

test-default-true --x/bool=true:
  return x

test-default-false --x/bool=false:
  return x

test-only-true --x/bool=true:
  return x

test-only-false --x/bool=false:
  return x
