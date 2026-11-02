// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Transport callbacks let host tests check failure and cleanup ordering.
run-standalone --health/Lambda --execute/Lambda --cancel/Lambda --recover/Lambda
    --cleanup/Lambda?=null:
  health.call
  returned := false
  failure/any := null
  cleanup-error/any := null
  try:
    failure = catch:
      if not execute.call: throw "EC618 test failed"
    returned = true
  finally:
    critical-do --no-respect-deadline:
      if failure or not returned:
        cancel-error := catch: cancel.call
        if cancel-error: print "EC618 cancellation failed: $cancel-error"
        recovery-error := catch: recover.call
        if recovery-error:
          print "EC618 recovery wait failed: $recovery-error"
          cleanup-error = recovery-error
      if cleanup:
        fixture-error := catch: cleanup.call
        if fixture-error:
          print "EC618 fixture cleanup failed: $fixture-error"
          cleanup-error = fixture-error
      health-error := catch: health.call
      if health-error:
        print "Final EC618 health failed: $health-error"
        cleanup-error = health-error
  if failure: throw failure
  if cleanup-error: throw cleanup-error
