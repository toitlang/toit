// Copyright (C) 2025 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test-literals
  test-getters

test-literals:
  id (identical null null)
  id (identical null true)
  id (identical null 0)
  id (identical null 0.0)
  id (identical null Map)

  id (identical true true)
  id (identical false false)
  id (identical true false)
  id (identical false true)

  id (identical Map Map)
  id (identical Map Set)

  id (identical 0 0)
  id (identical 0 0.0)
  id (identical 0.0 0)

test-getters:
  id (identical get-null get-null)
  id (identical get-null get-true)
  id (identical get-null get-int)
  id (identical get-null get-float)
  id (identical get-null get-map)

  id (identical get-true get-true)
  id (identical get-false get-false)
  id (identical get-true get-false)
  id (identical get-false get-true)

  id (identical get-map get-map)
  id (identical get-map get-set)

  id (identical get-int get-int)
  id (identical get-int get-float)
  id (identical get-float get-int)

get-null: return null
get-true: return true
get-false: return false
get-int: return 0
get-float: return 0.0
get-map: return Map
get-set: return Set

id x:
  return x
