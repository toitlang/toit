// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Calls the allowed (pure, process-local) primitives with random arguments of
right and wrong types. Every call must either return or throw; a VM crash
or abort is a finding.

Usage: toit run tests/fuzz/primitive-fuzz.toit -- <seed> <iterations> [<trace-from>]

The run is deterministic for a given seed. To reproduce a crash, rerun with
the same seed and a trace-from value at or below the last progress line:
every call from that iteration on is printed before it is made.

The wrappers are generated into primitives.toit by gen-primitive-fuzz.toit.
*/

import .primitives

// Deterministic PRNG (xorshift64*), independent of the VM's own 'random'
// (which the fuzzer itself reseeds through core.random-seed).
class Rng:
  state_/int := ?

  constructor seed/int:
    state_ = seed == 0 ? 0x1234_5678 : seed

  next -> int:
    x := state_
    x ^= x >>> 12
    x ^= x << 25
    x ^= x >>> 27
    state_ = x
    return (x * 0x2545F4914F6CDD1D) >>> 1

  next max/int -> int:
    return next % max

class Point:
  x := 1
  y := "y"
  constructor:
  constructor .x .y:

interesting-ints ::= [
  0, 1, -1, 2, 3, 7, 8, 15, 16, 31, 32, 33, 63, 64, 65, 127, 128, 255, 256,
  1000, 4096, 65535, 65536, 0x7fff_ffff, 0x8000_0000, 0xffff_ffff,
  0x1_0000_0000, 0x3fff_ffff, -(0x3fff_ffff) - 1,
  0x3fff_ffff_ffff_ffff, -(0x3fff_ffff_ffff_ffff) - 1,
  0x4000_0000_0000_0000, 0x7fff_ffff_ffff_ffff, int.MIN, int.MIN + 1,
  -2, -8, -64, -65, -256,
]

interesting-floats ::= [
  0.0, -0.0, 0.5, 1.0, -1.5, 3.14159, 1e10, 1e300, -1e300, 1e-300, 5e-324,
  float.MAX-FINITE, float.MIN-POSITIVE, float.INFINITY, -float.INFINITY,
  float.NAN,
]

big-string ::= "x" * 70_000

/**
Primitives whose size argument is only bounded by memory. They allocate
(and fill) the requested size without preemption, so arbitrary sizes make
the run slow or exhaust the host's memory (a known resource-exhaustion
issue, not a memory-safety one). Their integer arguments are bounded.
*/
SIZE-BOUNDED ::= {
  "core.array_new", "core.byte_array_new", "core.byte_array_new_external",
  "core.create_off_heap_byte_array", "crypto_random.random",
}
MAX-SIZE ::= 1 << 20

/// A fresh pool of argument values. Some primitives mutate their
/// arguments, so the pool is rebuilt regularly.
make-pool rng/Rng -> List:
  pool := []
  pool.add-all interesting-ints
  pool.add-all interesting-floats
  10.repeat: pool.add (rng.next - (rng.next))
  10.repeat: pool.add (rng.next 100) - 50
  pool.add-all [null, true, false]
  pool.add-all [
    "", "a", "hello world", "ünïcödé €", "\x00\x01\xff",
    "12345", "-42", "0x1f", "1e10", "nan", "  3.5  ", "[1, 2]", "\"json\"",
    "x" * 1000, big-string, "hello world"[2..7], big-string[100..200],
  ]
  pool.add-all [
    #[], #[0], #[1, 2, 3], #[0xff, 0xfe, 0xfd, 0xfc, 0xfb, 0xfa, 0xf9, 0xf8],
    ByteArray 16, ByteArray 100: it, ByteArray 5000: it * 7,
    (ByteArray 100: it)[10..20], "abc".to-byte-array,
    #[0x7b, 0x7d], ByteArray 1, ByteArray 33: 0xff,
  ]
  pool.add-all [
    [], [1, 2, 3], ["a", "b"], List 100: it,
    [1.5, null, "x", #[1]], ([1, 2, 3, 4, 5])[1..3],
  ]
  pool.add-all [
    {:}, {"a": 1, "b": 2}, {1: 2}, {"x"}, {1, 2, 3},
  ]
  pool.add-all [
    Point, Point 5 "five", (:: it), (:: 42), Exception_ "x" null,
  ]
  pool.add-all (adversarial-values rng)
  return pool

/**
Adversarial shapes, the kinds of arguments that found earlier bugs in the
  C++ primitives and encoders:
- collections whose size and backing fields the core library keeps
  consistent, but which a program can set to anything (the C++ consumers
  must validate them);
- self-referential and deeply nested collections and slices;
- program-heap (read-only) literals;
- empty and huge blobs, and external byte arrays.
*/
adversarial-values rng/Rng -> List:
  result := []
  // Lists whose size field is not within the backing, or not a smi, or whose
  // backing is not an array.
  [-1, 4, 100, 1 << 40, int.MIN, "x", null, 1.5].do: | size |
    list := [1, 2, 3]
    (list as List_).size_ = size
    result.add list
  [null, 7, "abc", #[1, 2], [1, 2], Array_ 0].do: | backing |
    list := [1, 2, 3]
    (list as List_).array_ = backing
    result.add list
  self-backed := [1, 2, 3]
  (self-backed as List_).array_ = self-backed
  result.add self-backed
  // List slices out of range (the constructor only checks slices of slices).
  result.add (ListSlice_ [1, 2, 3] 2 100)
  result.add (ListSlice_ [1, 2, 3] -5 2)
  result.add (ListSlice_ [1, 2, 3] 3 1)
  result.add (ListSlice_ [1, 2, 3] 0 (1 << 40))
  bogus-list := [1, 2, 3]
  (bogus-list as List_).size_ = 1000
  result.add (ListSlice_ bogus-list 0 500)
  result.add (ListSlice_ (Array_ 3) 1 3)
  // Maps and sets whose size, backing or index fields are inconsistent.
  [-1, 5, 1000, 1 << 40, "x"].do: | size |
    map := {"a": 1, "b": 2}
    map.size_ = size
    result.add map
    set := {1, 2, 3}
    set.size_ = size
    result.add set
  [null, 7, [1], Array_ 1, [1, 2, 3, 4, 5], "abc"].do: | backing |
    map := {"a": 1, "b": 2}
    map.backing_ = backing
    result.add map
  [null, 7, Array_ 0, Array_ 3, #[1, 2]].do: | index |
    map := {"a": 1, "b": 2}
    map.index_ = index
    result.add map
  self-map := {:}
  self-map["self"] = self-map
  result.add self-map
  self-map-backing := {"a": 1}
  self-map-backing.backing_ = self-map-backing
  result.add self-map-backing
  removed := {"a": 1, "b": 2, "c": 3}
  removed.remove "a"
  removed.remove "b"
  removed.size_ = 3
  result.add removed
  // Self-referential and deeply nested lists and arrays.
  cyclic := [1]
  cyclic.add cyclic
  result.add cyclic
  cyclic-array := Array_ 2
  cyclic-array[0] = cyclic-array
  result.add cyclic-array
  deep := []
  200.repeat: deep = [deep]
  result.add deep
  // Byte-array slices of slices, and copy-on-write arrays in odd states.
  chain := ByteArray 8: it
  50.repeat: chain = ByteArraySlice_ chain 0 (chain.size)
  result.add chain
  literal := #[1, 2, 3, 4]
  result.add literal
  literal-backing := (literal as CowByteArray_).backing_
  result.add literal-backing  // A byte array on the program heap.
  mutable-literal := CowByteArray_ literal-backing
  mutable-literal.is-mutable_ = true  // Claims the read-only backing is mutable.
  result.add mutable-literal
  odd-flag := CowByteArray_ (ByteArray 3) as ByteArray_
  odd-flag.is-mutable_ = 42
  result.add odd-flag
  result.add (ByteArraySlice_ literal 1 3)
  // String byte slices (no bounds checks in the constructor) cutting UTF-8
  // sequences and out of range.
  multi := "a\u{1F600}é€" as String_
  result.add (StringByteSlice_ multi 0 2)
  result.add (StringByteSlice_ multi 2 5)
  result.add (StringByteSlice_ multi 1 multi.size)
  result.add (StringByteSlice_ multi -1 3)
  result.add (StringByteSlice_ multi 0 1000)
  result.add (StringByteSlice_ multi 4 2)
  result.add multi[1..5]
  // Program-heap literals.
  result.add (Array_ 0)
  result.add "a program-heap literal string"
  result.add 0x7fff_ffff_ffff_ffff
  result.add 1.25
  // Empty and huge blobs, external byte arrays.
  result.add (ByteArray 0)
  result.add (ByteArray 20_000)  // External.
  result.add (ByteArray HUGE: it)
  result.add ("y" * HUGE)
  result.add ("\u{1F600}" * (HUGE / 4))
  result.add (ByteArray HUGE)[HUGE - 3..]
  // Tasks and other VM-interpreted instances.
  result.add Task.current
  return result

HUGE ::= 1 << 21

random-argument rng/Rng pool/List -> any:
  choice := rng.next 10
  if choice == 0: return interesting-ints[rng.next interesting-ints.size]
  if choice == 1: return rng.next 64
  return pool[rng.next pool.size]

describe value/any -> string:
  // Adversarial values have inconsistent fields, so their methods may throw.
  result := null
  catch:
    result = describe_ value
  return result or "<$(object-class-id_ value)>"

object-class-id_ value/any -> int:
  #primitive.core.object-class-id

describe_ value/any -> string:
  if value is string:
    s := value as string
    return s.size > 20 ? "string($s.size)" : "\"$s\""
  if value is ByteArray: return "ByteArray($((value as ByteArray).size))"
  if value is List: return "List($((value as List).size))"
  if value is Map: return "Map($((value as Map).size))"
  if value is int or value is float or value == null or value is bool: return "$value"
  return "<$(value.stringify)>"

/**
A pid that is never a live process (pids are not reused and count up from
  zero), so core.process_send exercises the message encoder (and the neutering
  of transferred external byte arrays) without delivering anything.
*/
NO-SUCH-PID ::= 0x3fff_fff0

/// Exceptions a denied primitive throws in an untrusted container.
DENIED-ERRORS ::= {"PERMISSION_DENIED", "PRIMITIVE_LOOKUP_FAILED"}

main args:
  seed := args.size > 0 ? int.parse args[0] : 1
  iterations := args.size > 1 ? int.parse args[1] : 100_000
  trace-from := args.size > 2 ? int.parse args[2] : -1
  rng := Rng seed
  // In an untrusted container most modules are denied. A primitive that only
  // ever throws a permission error is skipped after a few calls, so the run
  // spends its time on the allowed ones.
  untrusted := (catch: prim-core-program-name) == "PERMISSION_DENIED"
  print "mode: $(untrusted ? "untrusted" : "trusted")"
  pool := make-pool rng
  counts := List PRIMITIVE-COUNT: 0
  throws := List PRIMITIVE-COUNT: 0
  denied-throws := List PRIMITIVE-COUNT: 0
  start := Time.monotonic-us
  iterations.repeat: | iteration |
    if iteration % 1000 == 0:
      pool = make-pool rng
    if iteration % 100_000 == 0:
      print "progress: iteration $iteration ($(Duration --us=Time.monotonic-us - start))"
    index := rng.next PRIMITIVE-COUNT
    while untrusted and denied-throws[index] >= 20 and denied-throws[index] == counts[index]:
      index = rng.next PRIMITIVE-COUNT
    arity := PRIMITIVE-ARITIES[index]
    arguments := List arity: random-argument rng pool
    if SIZE-BOUNDED.contains PRIMITIVE-NAMES[index]:
      // crypto_random.random takes about 0.6s per MB.
      max := PRIMITIVE-NAMES[index] == "crypto_random.random" ? 1 << 14 : MAX-SIZE
      arguments.map --in-place: | arg |
        (arg is int and arg > max) ? arg % max : arg
    if PRIMITIVE-NAMES[index] == "core.add_finalizer" and arguments[1] is not Lambda:
      // The primitive accepts any finalizer, but the message loop in
      // lib/core/message_.toit only handles lambdas and fails an assertion
      // (in the system task) when the object dies.
      arguments[1] = :: null
    if PRIMITIVE-NAMES[index] == "core.process_send":
      arguments[0] = NO-SUCH-PID
    if trace-from >= 0 and iteration >= trace-from:
      print "$iteration: $PRIMITIVE-NAMES[index] $(arguments.map: describe it)"
    counts[index]++
    result := null
    call-start := Time.monotonic-us
    exception := catch:
      result = call-primitive index arguments
    elapsed := Time.monotonic-us - call-start
    if elapsed > 500_000:
      // Primitives are not preemptible: a slow call blocks a scheduler thread.
      print "slow: $iteration: $PRIMITIVE-NAMES[index] $(arguments.map: describe it) took $(Duration --us=elapsed)"
    if exception:
      throws[index]++
      if exception is string and DENIED-ERRORS.contains exception: denied-throws[index]++
    else if result != null and (rng.next 4) == 0:
      // Feed results (resources, contexts, new objects) back into the pool.
      pool[rng.next pool.size] = result
  never-returned := 0
  PRIMITIVE-COUNT.repeat:
    if counts[it] == throws[it]: never-returned++
  print "done: $iterations calls of $PRIMITIVE-COUNT primitives in $(Duration --us=Time.monotonic-us - start)"
  print "primitives that never succeeded: $never-returned"
  if untrusted:
    denied := 0
    PRIMITIVE-COUNT.repeat:
      if counts[it] > 0 and denied-throws[it] == counts[it]: denied++
    print "primitives denied in the untrusted container: $denied"
