// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show LITTLE_ENDIAN

/**
Contains various utility functions.
*/

/** The number of bits per byte. */
BITS_PER_BYTE ::= 8

/** The number of bits per word. */
BITS_PER_WORD ::= BYTES_PER_WORD * BITS_PER_BYTE

/** The number of bytes per word. */
BYTES_PER_WORD ::= word_size_

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
identical x y:
  #primitive.core.identical

/**
Returns the min of $a and $b.
Returns $a if $a and $b are equal.
Returns $float.NAN if either is $float.NAN.
Returns the smaller element, according to $Comparable.compare_to, otherwise.
*/
min a/Comparable b/Comparable: return (min_special_compare_to_ a b) ? a : b

/**
Returns true if this < other in the compare_to sense,
  but with the exception that Nan is smaller than anything
  else.
*/
min_special_compare_to_ lhs rhs -> bool:
  #primitive.core.min_special_compare_to:
    return (lhs.compare_to rhs) <= 0

/**
Returns the max of $a and $b.
Returns $a if $a and $b are equal.
Returns $float.NAN if either is $float.NAN.
Returns the greater element, according to $Comparable.compare_to, otherwise.
*/
max a/Comparable b/Comparable: return (a.compare_to b) >= 0 ? a : b

/**
Rounds a non-negative $value up to the next multiple of the $divisor.

# Examples
```
round_up 17 10  // => 20
round_up 7 2    // => 8
round_up -13 10 // => OUT_OF_RANGE error
```
*/
round_up value/int divisor/int -> int:
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
round_down value/int divisor/int -> int:
  if not (value >= 0 and divisor > 0): throw "OUT_OF_RANGE"
  mask ::= divisor - 1
  if mask & divisor == 0:
    return value & ~mask
  return value - value % divisor

/** Encodes $object into a ubjson encoded byte array. */
encode_ object:
  #primitive.core.encode_object

/** Encodes $exception, $message and the current stack trace into a ubjson encoded byte array. */
encode_error_ exception message -> ByteArray?:
  #primitive.core.encode_error:
    print_ "encode_error_ primitive failed: $exception, $message"
    return null

/**
Returns a random number in the range [0..0xFFF_FFFF] (inclusive).

The returned number is the result of a PRNG (pseudo random number generator). The seed
  of the PRNG can be changed by calling $set_random_seed.
*/
random:
  #primitive.core.random

/**
Returns a random number in the range [0..$n[ ($n exclusive).

The returned number is the result of a PRNG (pseudo random number generator). The seed
  of the PRNG can be changed by calling $set_random_seed.
*/
random n/int:
  if n <= 0: return 0
  return (random.to_float * n / 0x1000_0000).to_int

/** Returns a pseudo-random number from $start to $end - 1. */
random start/int end/int:
  return (random end - start) + start

/**
Seeds the random number generator with the $seed.
The $seed must be a byte array or a string.
Currently only the first 16 bytes of the $seed are used.
*/
set_random_seed seed:
  #primitive.core.random_seed

random_add_entropy_ data:
  #primitive.core.add_entropy

/**
Returns the number of initial zeros in the argument.
The argument is treated as an unsigned 64 bit number.  Thus
  it returns 64 if given the value 0, and it returns 0 if given
  a negative input.
*/
count_leading_zeros value/int:
  #primitive.core.count_leading_zeros

/**
Calls the given $block but throws an exception if the $timeout is exceeded.
If $timeout is null, calls the $block without a timeout.
*/
with_timeout timeout/Duration? [block]:
  if timeout:
    return with_timeout --us=timeout.in_us block
  else:
    return block.call

/**
Calls the given $block but throws an exception if a timeout of $ms milliseconds
  is exceeded.
*/
with_timeout --ms/int [block]:
  return with_timeout --us=ms*1000 block

/**
Calls the given $block but throws an exception if a timeout of $us microseconds
  is exceeded.
*/
with_timeout --us/int [block]:
  deadline := Time.monotonic_us + us
  return task.with_deadline_ deadline block

/**
Enters and calls the given critical $block.

Within $block, the current task won't be interrupted by cancellation exceptions.
  Instead such exceptions will be delayed until the $block is left. The critical
  $block can be interrupted by a timeout (see $with_timeout) if $respect_deadline is true.
*/
critical_do --respect_deadline/bool=true [block]:
  self ::= task
  deadline/int? := null
  self.critical_count_++
  if not respect_deadline:
    deadline = self.deadline_
    self.deadline_ = null
  try:
    block.call
  finally:
    if not respect_deadline:
      self.deadline_ = deadline
    self.critical_count_--

/**
Exits the VM with the given $status.

# Argument $status
0 signals a successful exit. All other statuses are error codes.
*/
exit status:
  if status == 0: __halt__
  else: __exit__ status

/**
Creates an off-heap byte array with the given $size.
Off-heap byte arrays are preferred when transferring data between
  applications.
*/
create_off_heap_byte_array size:
  #primitive.core.create_off_heap_byte_array

/** Concatenates the strings in the given $array_of_strings. */
concat_strings_ array_of_strings:
  #primitive.core.concat_strings

/** Constructs interpolated strings. */
interpolate_strings_ array:
  // Layout of array: [string, {format, object, string}*]
  for q := 1; q < array.size; q += 3:
    format_index := q + 1
    object := array[format_index]
    format := array[q]
    str := format ? string.format format object : object.stringify
    array[q] = str
    array[format_index] = ""
  return concat_strings_ array

/**
Constructs interpolated strings.
Used when there are no format specifications, that is all interpolations are
  used as-is without padding etc.
*/
simple_interpolate_strings_ array:
  // Layout of array: [string, {object, string}*]
  for q := 1; q < array.size; q += 2:
    array[q] = array[q].stringify
  return concat_strings_ array

// Query primitives for system information.

/** Returns a string identifying the underlying platform. */
platform:
  #primitive.core.platform

PLATFORM_FREERTOS ::= "FreeRTOS"
PLATFORM_WINDOWS ::= "Windows"
PLATFORM_MACOS ::= "macOS"
PLATFORM_LINUX ::= "Linux"

/**
Returns an array with stats for the current process.
The stats, listed by index in the array, are:
0. GC count
1. Allocated memory
2. Reserved memory
3. Process message count
4. Bytes allocated in object heap
5. Group ID
6. Process ID

The "bytes allocated in the heap" tracks the total number of allocations, but
  doesn't deduct the sizes of objects that die. It is a way to follow the
  allocation pressure of the process.  It corresponds to the value returned
  by $bytes_allocated_delta.

The "allocated memory" is the combined size of all live objects on the heap.
The "reserved memory" is the size of the heap.

By passing the optional $list argument to be filled in, you can avoid causing
  an allocation, which may interfere with the tracking of allocations.  But note
  that at some point the bytes_allocated number becomes so large that it needs
  a small allocation of its own.
*/
process_stats list/List=(List 7) -> List:
  result := process_stats_ list -1 -1
  assert: result  // The current process always exists.
  return result

/**
Variant of $(process_stats).

Returns an array with stats for the process identified by the $group and the
  $id.
*/
process_stats group id list/List=(List 7) -> List?:
  return process_stats_ list group id

process_stats_ list group id:
  #primitive.core.process_stats

/**
Returns the number of bytes allocated, since the last call to this function.
For the first call, returns number of allocated bytes since system start.
Deprecated.  This function doesn't nest.  Use $process_stats instead.
*/
bytes_allocated_delta -> int:
  #primitive.core.bytes_allocated_delta

/** Returns the number of garbage collections. */
gc_count -> int:
  #primitive.core.gc_count

// TODO(Lau): does it still make sense to say SDK here?
/**
Returns the Toit SDK version that this virtual machine has been built from.
*/
vm_sdk_version -> string:
  #primitive.core.vm_sdk_version

/** Returns information about who built this virtual machine. */
vm_sdk_info -> string:
  #primitive.core.vm_sdk_info

// TODO(Lau): does it still make sense to say SDK here?
/**
Returns the Toit SDK model that this virtual machine has been built from.
*/
vm_sdk_model -> string:
  #primitive.core.vm_sdk_model

// TODO(Lau): does it still make sense to say SDK here?
/** Returns the Toit SDK version that generated this application snapshot. */
app_sdk_version -> string:
  #primitive.core.app_sdk_version

/** Returns information about who build this application snapshot. */
app_sdk_info -> string:
  #primitive.core.app_sdk_info

// TODO: This is certainly not the right interface. We want to be able to set
// this from the system for other/new processes.
/** Sets the max size for the heap to $size. */
set_max_heap_size_ size/int -> none:
  #primitive.core.set_max_heap_size

serial_print_heap_report marker/string="" max_pages/int=0 -> none:
  #primitive.core.serial_print_heap_report

/** Simplistic profiler based on bytecode invocation counts. */
class Profiler:
  /**
  Installs the profiler.

  Profiles all tasks if $profile_all_tasks is true; otherwise only profiles the current task.
  */
  static install profile_all_tasks/bool -> none:
    #primitive.core.profiler_install

  /** Starts the profiler. */
  static start -> none:
    #primitive.core.profiler_start

  /** Stops the profiler. */
  static stop -> none:
    #primitive.core.profiler_stop

  /**
  Reports the result of the profiler with the $title.
  Only includes results above the $cutoff per mille.
  */
  static report title/string --cutoff/int=10 -> none:
    encoded_profile := encode title cutoff
    system_send_ SYSTEM_MIRROR_MESSAGE_ encoded_profile
    process_messages_

  /**
  Encodes the result of the profiler with the $title.
  Only includes results above the $cutoff per mille.
  */
  static encode title/string cutoff/int -> ByteArray:
    return encode_ title.copy cutoff

  // The title most be an actual String_, not a slice.
  static encode_ title/string cutoff/int -> ByteArray:
    #primitive.core.profiler_encode

  /** Uninstalls the profiler. */
  static uninstall -> none:
    #primitive.core.profiler_uninstall

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
literal_index_ o -> int?:
  #primitive.core.literal_index

word_size_ -> int:
  #primitive.core.word_size

/**
Converts a hex digit character in the ranges
  '0'-'9', 'a'-'f', or 'A'-'F'.
Returns the value between 0 and 15.
Calls the block on invalid input and returns its return value if any.
*/
hex_digit char/int [error_block] -> int:
  if '0' <= char <= '9': return char - '0'
  if 'a' <= char <= 'f': return 10 + char - 'a'
  if 'A' <= char <= 'F': return 10 + char - 'A'
  return error_block.call

/**
Converts a hex digit character in the ranges
  '0'-'9', 'a'-'f', or 'A'-'F'.
Returns the value between 0 and 15.
*/
hex_digit char/int -> int:
  return hex_digit char: throw "INVALID_ARGUMENT"

/**
Converts a number between 0 and 15 to a lower case
  hex digit.
*/
to_lower_case_hex c/int -> int:
  return "0123456789abcdef"[c]

/**
Converts a number between 0 and 15 to an upper case
  hex digit.
*/
to_upper_case_hex c/int -> int:
  return "0123456789ABCDEF"[c]

print_objects marker/string="" gc/bool=true:
  if gc:
    before := gc_count
    while gc_count == before: RecognizableFiller_
  print_histogram_ marker object_histogram_

class RecognizableFiller_:
  a/int := 0
  b/int := 0
  c/int := 0
  d/int := 0
  e/int := 0
  f/int := 0
  g/int := 0

class HistogramEntry_:
  index/int
  count/int := 0
  size/int := 0
  constructor .index .count .size:

  accumulate other -> none:
    count += other.count
    size += other.size

print_histogram_ marker/string histogram/ByteArray:
  entries := []
  (histogram.size / (2 * 4)).repeat:
    count := LITTLE_ENDIAN.uint32 histogram (it * 2 + 0) * 4
    size  := LITTLE_ENDIAN.uint32 histogram (it * 2 + 1) * 4
    if size > 0:
      entry := HistogramEntry_ it count size
      entries.add entry
  entries.sort --in_place: | a b | (b.size > a.size) ? 1 : (b.size < a.size ? -1 : 0)
  total := HistogramEntry_ -1 0 0
  entries.do: total.accumulate it

  if not marker.is_empty: marker = " @ $marker"
  print_ "*" * 16
  print_ "Objects$marker:"
  print_ "  ┌─────────┬─────────┬─────────┐"
  print_ "  │  Bytes  │  Count  │  Class  │"
  print_ "  ├─────────┼─────────┼─────────┤"
  entries.do:
    // We print the lines with standard | characters to make it easier to
    // work with the output using grep, cut, and other command line tools.
    print_ "  | $(%6d it.size)  | $(%6d it.count)  | $(%6d it.index)  |"
  print_ "  └─────────┴─────────┴─────────┘"
  print_ "  Total: $(total.size) bytes in $(total.count) objects"
  print_ "*" * 16

object_histogram_ -> ByteArray:
  #primitive.debug.object_histogram
