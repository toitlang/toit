// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .i2s-run-output

// Protocol mismatches must unwind through cleanup. Test assertions exit the
// process and therefore must not be used for fallible transport responses.
require-peer-reply expected/string actual/string:
  if actual != expected: throw "Expected peer <$expected>, received <$actual>"

// The transport operations are injected so failure ordering can be tested
// without hardware. Identification and initial health precede this function.
run-case ec/any verdict/I2sRunOutput image/ByteArray argument/string source/string
    --exchange/Lambda --cancel/Lambda --recover/Lambda --health/Lambda
    --peer-result/string?=null:
  running := false
  returned := false
  peer-reported := false
  failure/any := null
  cleanup-error/any := null
  cancel-error/any := null
  recovery-error/any := null
  health-error/any := null
  try:
    failure = catch:
      exchange.call "PREPARE $source" "READY"
      ec.send-arg argument
      ec.install-container image
      observer := :: |text/string|
        if verdict.accept text: exchange.call "START $source" "READY"
      running = true
      success := ec.run --timeout-ms=30_000 --on-output=observer
      running = not success
      if not success: throw "EC I2S container failed"
      if not verdict.passed: throw "Missing I2S payload verdict"
      if peer-result:
        peer-reported = true
        exchange.call "RESULT" peer-result
    returned = true
  finally:
    // Cancellation bypasses catch. Permit the bounded cleanup operations to
    // yield even when the caller was canceled or its deadline has expired.
    critical-do --no-respect-deadline:
      // An EC failure may be waiting on a failed peer. Collect its capture
      // diagnostics before STOP destroys them, preserving the original error.
      if failure and peer-result and verdict.armed and not peer-reported:
        peer-error := catch: exchange.call "RESULT" peer-result
        if peer-error: print "S3 failure report: $peer-error"
      cleanup-error = catch: exchange.call "STOP" "OK"
      cancel-error = running ? (catch: cancel.call) : null
      recovery-error = (failure or not returned) ? (catch: recover.call) : null
      health-error = catch: health.call
      if cleanup-error: print "S3 cleanup failed: $cleanup-error"
      if cancel-error: print "EC cancellation failed: $cancel-error"
      if recovery-error: print "EC recovery wait failed: $recovery-error"
      if health-error: print "Final EC health failed: $health-error"
  if failure: throw failure
  if cleanup-error: throw cleanup-error
  if cancel-error: throw cancel-error
  if recovery-error: throw recovery-error
  if health-error: throw health-error
