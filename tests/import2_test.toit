// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import monitor as m
import crypto.sha1 show Sha1

import .import2_a

import .import2_b as b

import .import2_c
import .import2_c as c

import .import2_d show f_d1
import .import2_dd  // Would clash with import2_d.

import .import2_e
import .import2_e as e

import .import2_f as f

import .import2_g

// Import 'f' and 'g' again, with different prefix.
import .import2_f as h
import .import2_g as h
import .import2_h as h  // Would conflict if too much was exported.

main:
  // Just try to instantiate library classes.
  m.Channel 5
  Sha1

  expect_equals "f_a" f_a

  expect_equals "f_b" b.f_b

  expect_equals "f_c" f_c
  expect_equals "f_c" c.f_c

  expect_equals "f_d1" f_d1
  expect_equals "f_d2" f_d2

  expect_equals "f_e" f_e
  expect_equals "f_e" e.f_e

  // Just try to instantiate library classes through 'f'.
  f.Map
  f.Buffer

  // Same for the libraries imported through 'g'. No prefix.
  Writer null

  h.Map
  h.Buffer
  h.Writer null
  expect_equals "h_List" h.List
  expect_equals "h_Response" (h.Response null null)
