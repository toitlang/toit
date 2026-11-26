// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

/**
The system process out of memory while it serves a request.

The primitives the system process calls for other processes (starting a
  container, writing an image, the flash registry) fail with an
  out-of-memory error instead of restarting the device when the system
  process can't allocate (src/out_of_memory.h). Their callers catch the
  error where the request starts and fail the request; any other allocation
  failure of the system process still restarts the device.
*/

/**
The pause before the second attempt of $with-out-of-memory-retry_: the
  memory the other processes hold shrinks at their next collections.
*/
OUT-OF-MEMORY-RETRY-DELAY-MS_ ::= 100

/**
Calls $block. If it fails because the system process is out of memory
  (each failed allocation was already tried again after a collection of
  the system process and one of all processes), waits a moment and calls
  it once more. Throws "OUT_OF_MEMORY" if that fails for lack of memory too.

The $block must leave nothing behind when it fails.

With $relieve (for requests of trusted code and the system's own
  operations, never for starting a sandbox), sandboxed containers lose
  before the request fails: if the second attempt fails too, the sandboxed
  containers are stopped one at a time ($out-of-memory-relief_, the one
  holding the most memory first), each followed by another attempt, until
  the block succeeds or none is left. Asking the sandboxes to give memory
  back is already done before: each failed allocation was tried again
  after a collection of every process.
*/
with-out-of-memory-retry_ --relieve/bool=false [block] -> any:
  catch --unwind=(: not is-out-of-memory-error_ it):
    return block.call
  sleep --ms=OUT-OF-MEMORY-RETRY-DELAY-MS_
  catch --unwind=(: not is-out-of-memory-error_ it):
    return block.call
  if relieve:
    while true:
      relief := out-of-memory-relief_
      if not relief or not relief.call: break
      // The stopped container's memory is freed when its processes end.
      sleep --ms=OUT-OF-MEMORY-RETRY-DELAY-MS_
      catch --unwind=(: not is-out-of-memory-error_ it):
        return block.call
  throw "OUT_OF_MEMORY"

/**
Stops one sandboxed container to free memory for the system process and
  returns true, or returns false if no sandboxed container can be stopped.
  Installed by the container manager.
*/
out-of-memory-relief_/Lambda? := null
