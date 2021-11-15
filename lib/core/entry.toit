// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

ARGS_ := null
DEFINES_ := null

args_:
  cached := ARGS_
  if cached: return cached
  process_arguments_
  return ARGS_

defines_:
  cached := DEFINES_
  if cached: return cached
  process_arguments_
  return DEFINES_

arguments_:
  #primitive.core.args

process_define_ str [absent]:
  if not str.starts_with "-D": absent.call
  index := str.index_of "=" 2 --if_absent=absent
  if index == 2: absent.call
  key := str.copy 2 index
  DEFINES_[key] = str.copy index + 1

process_argument_ arg -> none:
  process_define_ arg:
    ARGS_.add arg
    return

// We split the passed command line arguments into args and defines.
// A command line argument in the form "-Dkey=value" will end up the defines.
// The rest is accumulated in args.
process_arguments_:
  ARGS_ = []
  DEFINES_ = {:}
  arguments_.do: process_argument_ it

// This is the system entry point. It is responsible for
// calling the main function and halting the system after
// it returns.
__entry__ -> none:
  task.initialize_entry_task_
  task.evaluate_:: #primitive.intrinsics.main args_
