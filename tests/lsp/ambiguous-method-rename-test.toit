// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: when a method name+shape is unique across the program (no other
// unrelated class defines it), all virtual call sites are included
// unconditionally. When the name IS ambiguous (multiple unrelated hierarchies
// define it), virtual calls are included only if they're in the same package
// as the target method's holder class.
//
// In this single-file test everything is in the same package, so ambiguous
// calls from the same package are still included. Cross-package exclusion
// would require a multi-file test.

// --- Unique method name (no ambiguity) ---

class Greeter:
  greet name/string -> string:
/*^
  3
*/
    return "hello $name"

use-greeter g/Greeter:
  g.greet "world"

// --- Ambiguous method name: two unrelated hierarchies define "run" ---

class Processor:
  run -> none:
/*^
  3
*/
    // does processing

class Timer:
  run -> none:
    // does timing

use-processor p/Processor:
  p.run

main:
  greeter := Greeter
  greeter.greet "toit"

  processor := Processor
  processor.run
