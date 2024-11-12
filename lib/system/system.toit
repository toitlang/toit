// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.trace show send-trace-message
import system.storage

/**
System related functionality.

This module contains functions that provide information about the currently
  running Toit program, as well as the system itself, such as the platform and
  architecture.  It also provides functions to collect statistics about the
  system and the current process.
*/

// Use lazy initialization to delay opening the storage bucket
// until we need it the first time. From that point forward,
// we keep it around forever.
bucket_/storage.Bucket ::= storage.Bucket.open --flash "toitlang.org/system"

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
  that at some point the bytes-allocated number becomes so large that it needs
  a small allocation of its own.

# Examples
```
print "There have been $(process-stats[STATS-INDEX-GC-COUNT]) GCs for this process"
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

/**
Sets the system tradeoff between memory use and speed.
The $percent argument is a number between 0 and 100, where 0 means that the
  system should use as little memory as possible, and 100 means that the system
  should run as fast as possible.
Host platforms default to high performance, while embedded platforms
  default to low memory use.
This setting is global, applying to all Toit processes running on the embedded
  system, and all Toit processes running in a host process.
*/
tune-memory-use percent/int -> none:
  #primitive.core.tune-memory-use

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

/**
Returns the name of the toit file, image, snapshot, or executable that the
  current program was run from.

If the program is run by the Toit command line tool, this is the name of the
  source file passed to the tool.
If the program is run as an executable, this is the name of the executable. In
  this case it is equivalent to argv[0] in C, or $0 in bash.

May return null if this information is not available.
*/
program-name -> string?:
  #primitive.core.program-name

/**
Returns the fully resolved path to the toit file, image, or snapshot that the
  current program was run from.

If the program is run by the Toit command line tool, this is the fully resolved
  path to the source file passed to the tool, as provided by `realpath`.

If the program is run as an executable, this is the fully resolved path to the
  executable.
*/
program-path -> string?:
  #primitive.core.program-path

/**
The hostname of the machine running the program.
*/
hostname -> string:
  if platform == PLATFORM-FREERTOS:
    config-name := bucket_.get "hostname"
    if config-name: return config-name
  return hostname_

/**
Sets the hostname of the machine running the program.

This operation is not supported on all platforms.

Only new network connections will use the new hostname. Also, some
  routers may cache the old hostname for a while.
*/
hostname= hostname/string -> none:
  if platform != PLATFORM-FREERTOS:
    throw "UNSUPPORTED"
  bucket_["hostname"] = hostname

hostname_ -> string:
  #primitive.core.hostname
