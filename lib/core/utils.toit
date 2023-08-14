// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show LITTLE-ENDIAN
import system.trace show send-trace-message

/**
Contains various utility functions.
*/

/** The number of bits per byte. */
BITS-PER-BYTE ::= 8

/** The number of bits per word. */
BITS-PER-WORD ::= BYTES-PER-WORD * BITS-PER-BYTE

/** The number of bytes per word. */
BYTES-PER-WORD ::= word-size_

/** The number of bytes per kilobyte. */
KB ::= 1024

/** The number of bytes per megabyte. */
MB ::= 1024 * 1024

/**
Whether $x and $y are identical objects.
Every object is identical to itself.
For numbers, two objects are furthermore identical if they
  have the same numeric value. Contrary to `==` two numbers must be of the
  same type, and have the same bit-pattern. As such, `-0.0 == 0.0`, but not
  `identical -0.0 0.0`.
Two strings are identical if they contain the same characters. For example,
  we have `identical "tw" + "in" "twin"`.
For floats, two NaN's (not-a-number) are identical when they have the same
  bits. For example, we have `identical float.NAN float.NAN`, but not
  `identical float.NAN (float.from_bits float.NAN.bits + 1)`. This is unlike
  `==` where NaN's are never equal, so `float.NAN == float.NAN` is always
  false.
*/
identical x/any y/any -> bool:
  // Recognized by the compiler and implemented as separate bytecode.
  unreachable

/**
Returns the min of $a and $b.
Returns $a if $a and $b are equal.
Returns $float.NAN if either is $float.NAN.
Returns the smaller element, according to $Comparable.compare-to, otherwise.
*/
min a/Comparable b/Comparable: return (min-special-compare-to_ a b) ? a : b

/**
Returns true if this < other in the compare_to sense,
  but with the exception that Nan is smaller than anything
  else.
*/
min-special-compare-to_ lhs rhs -> bool:
  #primitive.core.min-special-compare-to:
    return (lhs.compare-to rhs) <= 0

/**
Returns the max of $a and $b.
Returns $a if $a and $b are equal.
Returns $float.NAN if either is $float.NAN.
Returns the greater element, according to $Comparable.compare-to, otherwise.
*/
max a/Comparable b/Comparable: return (a.compare-to b) >= 0 ? a : b

/**
Rounds a non-negative $value up to the next multiple of the $divisor.

# Examples
```
round_up 17 10  // => 20
round_up 7 2    // => 8
round_up -13 10 // => OUT_OF_RANGE error
```
*/
round-up value/int divisor/int -> int:
  if not (value >= 0 and divisor > 0): throw "OUT_OF_RANGE"
  mask ::= divisor - 1
  if mask & divisor == 0:
    return (value + mask) & ~mask
  return ((value + mask) / divisor) * divisor

/**
Rounds a non-negative $value down to the previous multiple of the $divisor.

# Examples
```
round_down 27 10  // => 20
round_down 7 2    // => 6
round_down -13 10 // => OUT_OF_RANGE error
```
*/
round-down value/int divisor/int -> int:
  if not (value >= 0 and divisor > 0): throw "OUT_OF_RANGE"
  mask ::= divisor - 1
  if mask & divisor == 0:
    return value & ~mask
  return value - value % divisor

/** Encodes $object into a ubjson encoded byte array. */
encode_ object:
  #primitive.core.encode-object

/** Encodes $exception, $message and the current stack trace into a ubjson encoded byte array. */
encode-error_ exception message -> ByteArray?:
  #primitive.core.encode-error:
    print_ "encode_error_ primitive failed: $exception, $message"
    return null

/**
Returns a random number in the range [0..0xFFF_FFFF] (inclusive).

The returned number is the result of a PRNG (pseudo random number generator). The seed
  of the PRNG can be changed by calling $set-random-seed.
*/
random:
  #primitive.core.random

/**
Returns a random number in the range [0..$n[ ($n exclusive).

The returned number is the result of a PRNG (pseudo random number generator). The seed
  of the PRNG can be changed by calling $set-random-seed.
*/
random n/int:
  if n <= 0: return 0
  return (random.to-float * n / 0x1000_0000).to-int

/** Returns a pseudo-random number from $start to $end - 1. */
random start/int end/int:
  return (random end - start) + start

/**
Seeds the random number generator with the $seed.
The $seed must be a byte array or a string.
Currently only the first 16 bytes of the $seed are used.
*/
set-random-seed seed:
  #primitive.core.random-seed

random-add-entropy_ data:
  #primitive.core.add-entropy

/**
Returns the number of initial zeros in binary representation of the argument.
The argument is treated as an unsigned 64 bit number.  Thus
  it returns 0 if given a negative input.
#Deprecated.  Use $int.count_leading_zeros instead.
*/
count-leading-zeros value/int:
  #primitive.core.count-leading-zeros

/**
Calls the given $block but throws an exception if the $timeout is exceeded.
If $timeout is null, calls the $block without a timeout.
*/
with-timeout timeout/Duration? [block]:
  if timeout:
    return with-timeout --us=timeout.in-us block
  else:
    return block.call

/**
Calls the given $block but throws an exception if a timeout of $ms milliseconds
  is exceeded.
*/
with-timeout --ms/int [block]:
  return with-timeout --us=ms*1000 block

/**
Calls the given $block but throws an exception if a timeout of $us microseconds
  is exceeded.
*/
with-timeout --us/int [block]:
  deadline := Time.monotonic-us + us
  return Task_.current.with-deadline_ deadline block

/**
Enters and calls the given critical $block.

Within $block, the current task won't be interrupted by cancellation exceptions.
  Instead such exceptions will be delayed until the $block is left. The critical
  $block can be interrupted by a timeout (see $with-timeout) if $respect-deadline is true.
*/
critical-do --respect-deadline/bool=true [block]:
  self ::= Task_.current
  deadline/int? := null
  self.critical-count_++
  if not respect-deadline:
    deadline = self.deadline_
    self.deadline_ = null
  try:
    block.call
  finally:
    if not respect-deadline:
      self.deadline_ = deadline
    self.critical-count_--

/**
Exits the VM with the given $status.

# Argument $status
0 signals a successful exit. All other statuses are error codes.
*/
exit status/int -> none:
  __exit__ status

/**
Creates an off-heap byte array with the given $size.
Off-heap byte arrays are preferred when transferring data between
  applications.
*/
create-off-heap-byte-array size:
  #primitive.core.create-off-heap-byte-array

/** Concatenates the strings in the given $array-of-strings. */
concat-strings_ array-of-strings:
  #primitive.core.concat-strings

/** Constructs interpolated strings. */
interpolate-strings_ array:
  // Layout of array: [string, {format, object, string}*]
  for q := 1; q < array.size; q += 3:
    format-index := q + 1
    object := array[format-index]
    format := array[q]
    str := format ? string.format format object : object.stringify
    array[q] = str
    array[format-index] = ""
  return concat-strings_ array

/**
Constructs interpolated strings.
Used when there are no format specifications, that is all interpolations are
  used as-is without padding etc.
*/
simple-interpolate-strings_ array:
  // Layout of array: [string, {object, string}*]
  for q := 1; q < array.size; q += 2:
    array[q] = array[q].stringify
  return concat-strings_ array

// Query primitives for system information.

/** Returns a string identifying the underlying platform. */
platform:
  #primitive.core.platform

PLATFORM-FREERTOS ::= "FreeRTOS"
PLATFORM-WINDOWS ::= "Windows"
PLATFORM-MACOS ::= "macOS"
PLATFORM-LINUX ::= "Linux"

LINE-TERMINATOR ::= platform == PLATFORM-WINDOWS ? "\r\n" : "\n"

/// Index for $process-stats.
STATS-INDEX-GC-COUNT                       ::= 0
/// Index for $process-stats.
STATS-INDEX-ALLOCATED-MEMORY               ::= 1
/// Index for $process-stats.
STATS-INDEX-RESERVED-MEMORY                ::= 2
/// Index for $process-stats.
STATS-INDEX-PROCESS-MESSAGE-COUNT          ::= 3
/// Index for $process-stats.
STATS-INDEX-BYTES-ALLOCATED-IN-OBJECT-HEAP ::= 4
/// Index for $process-stats.
STATS-INDEX-GROUP-ID                       ::= 5
/// Index for $process-stats.
STATS-INDEX-PROCESS-ID                     ::= 6
/// Index for $process-stats.
STATS-INDEX-SYSTEM-FREE-MEMORY             ::= 7
/// Index for $process-stats.
STATS-INDEX-SYSTEM-LARGEST-FREE            ::= 8
/// Index for $process-stats.
STATS-INDEX-FULL-GC-COUNT                  ::= 9
/// Index for $process-stats.
STATS-INDEX-FULL-COMPACTING-GC-COUNT       ::= 10
// The size the list needs to have to contain all these stats.  Must be last.
STATS-LIST-SIZE_                           ::= 11

/**
Collect statistics about the system and the current process.
The $gc flag indicates whether a garbage collection should be performed
  before collecting the stats.  This is a fairly expensive operation, so
  it should be avoided if possible.
Returns an array with stats for the current process.
The stats, listed by index in the array, are:
0. New-space (small collection) GC count for the process
1. Allocated memory on the Toit heap of the process
2. Reserved memory on the Toit heap of the process
3. Process message count
4. Bytes allocated in object heap
5. Group ID
6. Process ID
7. Free memory in the system
8. Largest free area in the system
9. Full GC count for the process (including compacting GCs)
10. Full compacting GC count for the process

The "bytes allocated in the heap" tracks the total number of allocations, but
  doesn't deduct the sizes of objects that die. It is a way to follow the
  allocation pressure of the process.  It corresponds to the value returned
  by $bytes-allocated-delta.

The "allocated memory" is the combined size of all live objects on the heap.
The "reserved memory" is the size of the heap.

By passing the optional $list argument to be filled in, you can avoid causing
  an allocation, which may interfere with the tracking of allocations.  But note
  that at some point the bytes_allocated number becomes so large that it needs
  a small allocation of its own.

# Examples
```
print "There have been $((process_stats)[STATS_INDEX_GC_COUNT]) GCs for this process"
```
*/
process-stats --gc/bool=false list/List=(List STATS-LIST-SIZE_) -> List:
  full-gcs/int? := null
  if gc:
    full-gcs = (process-stats list)[STATS-INDEX-FULL-GC-COUNT]
  result := process-stats_ list -1 -1 full-gcs
  assert: result  // The current process always exists.
  return result

/**
Variant of $(process-stats).

Returns an array with stats for the process identified by the $group and the
  $id.
*/
process-stats --gc/bool=false group id list/List=(List STATS-LIST-SIZE_) -> List?:
  full-gcs/int? := null
  if gc:
    full-gcs = (process-stats list)[STATS-INDEX-FULL-GC-COUNT]
  return process-stats_ list group id full-gcs

process-stats_ list group id gc-count:
  #primitive.core.process-stats

/**
Returns the number of bytes allocated, since the last call to this function.
For the first call, returns number of allocated bytes since system start.
Deprecated.  This function doesn't nest.  Use $process-stats instead.
*/
bytes-allocated-delta -> int:
  #primitive.core.bytes-allocated-delta

/** Returns the number of garbage collections. */
gc-count -> int:
  #primitive.core.gc-count

// TODO(Lau): does it still make sense to say SDK here?
/**
Returns the Toit SDK version that this virtual machine has been built from.
*/
vm-sdk-version -> string:
  #primitive.core.vm-sdk-version

/** Returns information about who built this virtual machine. */
vm-sdk-info -> string:
  #primitive.core.vm-sdk-info

// TODO(Lau): does it still make sense to say SDK here?
/**
Returns the Toit SDK model that this virtual machine has been built from.
*/
vm-sdk-model -> string:
  #primitive.core.vm-sdk-model

// TODO(Lau): does it still make sense to say SDK here?
/** Returns the Toit SDK version that generated this application snapshot. */
app-sdk-version -> string:
  #primitive.core.app-sdk-version

/** Returns information about who build this application snapshot. */
app-sdk-info -> string:
  #primitive.core.app-sdk-info

// TODO: This is certainly not the right interface. We want to be able to set
// this from the system for other/new processes.
/** Sets the max size for the heap to $size. */
set-max-heap-size_ size/int -> none:
  #primitive.core.set-max-heap-size

serial-print-heap-report marker/string="" max-pages/int=0 -> none:
  #primitive.core.serial-print-heap-report

/** Simplistic profiler based on bytecode invocation counts. */
class Profiler:
  /**
  Installs the profiler.

  Profiles all tasks if $profile-all-tasks is true; otherwise only profiles the current task.
  */
  static install profile-all-tasks/bool -> none:
    #primitive.core.profiler-install

  /** Starts the profiler. */
  static start -> none:
    #primitive.core.profiler-start

  /** Stops the profiler. */
  static stop -> none:
    #primitive.core.profiler-stop

  /**
  Reports the result of the profiler with the $title.
  Only includes results above the $cutoff per mille.
  */
  static report title/string --cutoff/int=10 -> none:
    encoded-profile := encode title cutoff
    send-trace-message encoded-profile

  /**
  Encodes the result of the profiler with the $title.
  Only includes results above the $cutoff per mille.
  */
  static encode title/string cutoff/int -> ByteArray:
    return encode_ title.copy cutoff

  // The title most be an actual String_, not a slice.
  static encode_ title/string cutoff/int -> ByteArray:
    #primitive.core.profiler-encode

  /** Uninstalls the profiler. */
  static uninstall -> none:
    #primitive.core.profiler-uninstall

  /** Calls the $block while the profiler is active. */
  static do [block] -> any:
    try:
      start
      return block.call
    finally:
      stop

/**
Returns the literal index of the given object $o, or null if the object wasn't
  recognized as literal.

This function can be slow as it requires a linear search for objects.
*/
literal-index_ o -> int?:
  #primitive.core.literal-index

word-size_ -> int:
  #primitive.core.word-size

/// Deprecated.
hex-digit char/int [error-block] -> int:
  return hex-char-to-value char --on-error=error-block

/// Deprecated.
hex-digit char/int -> int:
  return hex-char-to-value char --on-error=(: throw "INVALID_ARGUMENT")

/**
Converts a hex digit character in the ranges
  '0'-'9', 'a'-'f', or 'A'-'F'.
Returns the value between 0 and 15.
Calls the block on invalid input and returns its return value if any.
*/
hex-char-to-value char/int [--on-error] -> int:
  if '0' <= char <= '9': return char - '0'
  if 'a' <= char <= 'f': return 10 + char - 'a'
  if 'A' <= char <= 'F': return 10 + char - 'A'
  return on-error.call

/**
Converts a hex digit character in the ranges
  '0'-'9', 'a'-'f', or 'A'-'F'.
Returns the value between 0 and 15.
*/
hex-char-to-value char/int -> int:
  return hex-char-to-value char --on-error=(: throw "INVALID_ARGUMENT")

/**
Converts a number between 0 and 15 to a lower case
  hex digit.
*/
to-lower-case-hex c/int -> int:
  return "0123456789abcdef"[c]

/**
Converts a number between 0 and 15 to an upper case
  hex digit.
*/
to-upper-case-hex c/int -> int:
  return "0123456789ABCDEF"[c]

/**
Produces a histogram of object types and their memory
  requirements.  The histogram is sent as a system
  mirror message, which means it is usually printed on
  the console.
*/
print-objects marker/string="" gc/bool=true:
  full-gcs := (process-stats)[STATS-INDEX-FULL-GC-COUNT]
  encoded-histogram := object-histogram_ marker full-gcs
  send-trace-message encoded-histogram

object-histogram_ marker/string full-gcs/int -> ByteArray:
  #primitive.debug.object-histogram
