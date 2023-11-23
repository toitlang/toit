// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.trace show send-trace-message

/** The number of bits per byte. */
BITS-PER-BYTE ::= 8

/** The number of bits per word. */
BITS-PER-WORD ::= BYTES-PER-WORD * BITS-PER-BYTE

/** The number of bytes per word. */
BYTES-PER-WORD ::= word-size_

/** Return value from $platform. */
PLATFORM-FREERTOS ::= "FreeRTOS"

/** Return value from $platform. */
PLATFORM-WINDOWS ::= "Windows"

/** Return value from $platform. */
PLATFORM-MACOS ::= "macOS"

/** Return value from $platform. */
PLATFORM-LINUX ::= "Linux"

/** Returns a string identifying the underlying platform. */
platform -> string:
  #primitive.core.platform

/** Return value from $architecture. */
ARCHITECTURE-ARM64 ::= "arm64"

/** Return value from $architecture. */
ARCHITECTURE-ARM ::= "arm"

/** Return value from $architecture. */
ARCHITECTURE-X86 ::= "x86"

/** Return value from $architecture. */
ARCHITECTURE-X86-64 ::= "x86_64"

/** Return value from $architecture. */
ARCHITECTURE-ESP32 ::= "esp32"

/** Return value from $architecture. */
ARCHITECTURE-ESP32S2 ::= "esp32s2"

/** Return value from $architecture. */
ARCHITECTURE-ESP32S3 ::= "esp32s3"

/** Return value from $architecture. */
ARCHITECTURE-ESP32C3 ::= "esp32c3"

/** Returns a string identifying the underlying architecture. */
architecture -> string:
  #primitive.core.architecture

/** Returns either "\r\n" or "\n" depending on the underlying platform. */
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

serial-print-heap-report marker/string="" max-pages/int=0 -> none:
  #primitive.core.serial-print-heap-report

word-size_ -> int:
  #primitive.core.word-size

/**
Produces a histogram of object types and their memory
  requirements.  The histogram is sent as a system
  mirror message, which means it is usually printed on
  the console.
*/
print-objects --marker/string="" --gc/bool=false -> none:
  full-gcs/int? := null
  if gc:
    list := List STATS-INDEX-FULL-GC-COUNT + 1
    full-gcs = (process-stats list)[STATS-INDEX-FULL-GC-COUNT]
  encoded-histogram := object-histogram_ marker full-gcs
  send-trace-message encoded-histogram

object-histogram_ marker/string full-gcs/int? -> ByteArray:
  #primitive.debug.object-histogram
