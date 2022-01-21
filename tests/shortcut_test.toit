// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

/// Test that visit-for-control works correctly.
main:
  marker := null
  if null:
    marker = "bad"
  else:
    marker = "good"
  expect_equals "good" marker

  marker = null
  if false:
    marker = "bad"
  else:
    marker = "good"
  expect_equals "good" marker

  marker = null
  if 0:
    marker = "good"
  else:
    marker = "bad"
  expect_equals "good" marker

  marker = null
  if "":
    marker = "good"
  else:
    marker = "bad"
  expect_equals "good" marker

  marker = null
  if 0:
    marker = "good"
  else:
    marker = "bad"
  expect_equals "good" marker

  marker = null
  if ' ':
    marker = "good"
  else:
    marker = "bad"
  expect_equals "good" marker

  marker = null
  if 0.0:
    marker = "good"
  else:
    marker = "bad"
  expect_equals "good" marker

  marker = null
  if not false:
    marker = "good"
  else:
    marker = "bad"
  expect_equals "good" marker

  marker = null  // <here
  if not true:
    marker = "bad"
  else:
    marker = "good"
  expect_equals "good" marker

  marker = null
  if true or true:
    marker = "good"
  else:
    marker = "bad"
  expect_equals "good" marker

  marker = null
  if true or false:
    marker = "good"
  else:
    marker = "bad"
  expect_equals "good" marker

  marker = null
  if false or true:
    marker = "good"
  else:
    marker = "bad"
  expect_equals "good" marker

  marker = null
  if false or false:
    marker = "bad"
  else:
    marker = "good"
  expect_equals "good" marker

  marker = null
  if true and true:
    marker = "good"
  else:
    marker = "bad"
  expect_equals "good" marker

  marker = null
  if true and false:
    marker = "bad"
  else:
    marker = "good"
  expect_equals "good" marker

  marker = null
  if false and true:
    marker = "bad"
  else:
    marker = "good"
  expect_equals "good" marker

  marker = null
  if false and false:
    marker = "bad"
  else:
    marker = "good"
  expect_equals "good" marker

  marker = null
  if not false and not false:
    marker = "good"
  else:
    marker = "false"
  expect_equals "good" marker
