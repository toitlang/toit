// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Only runs on the Wasm platform. See tools/wasm/run-tests.py.

import expect show *
import js

main:
  test-eval
  test-call
  test-concurrent-calls

test-eval:
  expect-equals 3 (js.eval "1 + 2")
  expect-equals "hello" (js.eval "'hel' + 'lo'")
  expect-structural-equals [1, 2, {"a": true}] (js.eval "[1, 2, {a: true}]")
  expect-equals "ü€😀" (js.eval "'\\u00fc\\u20ac\\ud83d\\ude00'")
  expect-null (js.eval "undefined")
  expect-null (js.eval "(function() {})")
  expect-equals "ReferenceError: nonExisting is not defined"
      catch: js.eval "nonExisting()"
  expect-equals "TypeError: Do not know how to serialize a BigInt"
      catch: js.eval "1n"
  // Globals survive between evaluations.
  js.eval "globalThis.counter = 41"
  expect-equals 42 (js.eval "++counter")

test-call:
  js.eval """
    globalThis.add = (a, b) => a + b;
    globalThis.slow = (s, ms) => new Promise((resolve) => setTimeout(() => resolve('slow:' + s), ms));
    globalThis.fail = () => { throw new Error('nope'); };
    globalThis.failAsync = async () => { throw new Error('async nope'); };
    """
  expect-equals 7 (js.call "add" [3, 4])
  // Dotted names are looked up from the global object, and called with
  // the right receiver.
  expect-structural-equals {"x": [1, 2]} (js.call "Object.fromEntries" [[["x", [1, 2]]]])
  expect-equals 9 (js.call "Math.max" [3, 9, 2])
  expect-equals "[1,2]" (js.call "JSON.stringify" [[1, 2]])
  expect-equals "TypeError: 'Math.nothing' is not a function" (catch: js.call "Math.nothing")
  expect-equals "TypeError: 'nothing.at.all' is not a function" (catch: js.call "nothing.at.all")
  start := Time.monotonic-us
  expect-equals "slow:x" (js.call "slow" ["x", 50])
  expect (Time.monotonic-us - start) >= 45_000
  expect-equals "Error: nope" (catch: js.call "fail")
  expect-equals "Error: async nope" (catch: js.call "failAsync")
  expect-equals "TypeError: 'missing' is not a function" (catch: js.call "missing")
  expect-equals "3.5" (js.call "String" [3.5])

test-concurrent-calls:
  // Other tasks keep running while one waits for a promise.
  results := []
  done := 0
  3.repeat: | i |
    task::
      results.add (js.call "slow" ["t$i", 30 - i * 10])
      done++
  ticks := 0
  while done < 3:
    ticks++
    sleep --ms=1
  expect-equals ["slow:t2", "slow:t1", "slow:t0"] results
  expect ticks > 3
