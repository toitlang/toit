// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import monitor as m
import crypto.sha1 show Sha1

import .import2-a

import .import2-b as b

import .import2-c
import .import2-c as c

import .import2-d show f-d1
import .import2-dd  // Would clash with import2_d.

import .import2-e
import .import2-e as e

import .import2-f as f

import .import2-g

// Import 'f' and 'g' again, with different prefix.
import .import2-f as h
import .import2-g as h
import .import2-h as h  // Would conflict if too much was exported.

main:
  // Just try to instantiate library classes.
  m.Channel 5
  Sha1

  expect-equals "f_a" f-a

  expect-equals "f_b" b.f-b

  expect-equals "f_c" f-c
  expect-equals "f_c" c.f-c

  expect-equals "f_d1" f-d1
  expect-equals "f_d2" f-d2

  expect-equals "f_e" f-e
  expect-equals "f_e" e.f-e

  // Just try to instantiate library classes through 'f'.
  f.Map
  f.Buffer

  // Same for the libraries imported through 'g'. No prefix.
  Channel 1

  h.Map
  h.Buffer
  h.Channel 1
  expect-equals "h_List" h.List
  expect-equals "h_Response" (h.Response null null)
