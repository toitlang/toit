// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// Utility for measuring execution time and memory allocations for a block
// and then printing the results.
log_execution_time name/string --iterations/int=1 --allocations/bool=true [block] -> none:
  assert: iterations > 0
  stats := List 5
  process_stats stats
  bytes_allocated := stats[4]

  duration ::= Duration.of:
    iterations.repeat: block.call

  process_stats stats
  bytes_allocated = stats[4] - bytes_allocated

  if iterations == 1:
    print "$name: $(%.2f duration.in_us/1000.0) ms"
    if allocations: print "$name: $(%.3f bytes_allocated/1000.0) kb"
  else:
    print "$name - time per iteration: $(%.2f duration.in_us/1000.0/iterations) ms (total $duration)"
    if allocations: print "$name - allocated per iteration: $(%.3f bytes_allocated/1000.0/iterations) kb"
