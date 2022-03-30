// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Spawns a new process that starts executing the given lambda.
The new process does not share any memory with the spawning process. If the lambda
  captures variables, those are copied to the new process.
May throw if the captured variables can't be serialized.
*/
spawn lambda/Lambda -> int:
  return hatch_primitive_ lambda.method_ lambda.arguments_

/**
Deprecated. Use $spawn instead.
*/
hatch_ lambda/Lambda:
  return spawn lambda

hatch_primitive_ method arguments:
  #primitive.core.hatch

// Entry point for process just being hatched.
__hatch_entry__:
  current := task
  current.initialize_entry_task_
  lambda := Lambda.__
      hatch_method_
      hatch_args_
  current.evaluate_ lambda

hatch_method_:
  #primitive.core.hatch_method

hatch_args_:
  #primitive.core.hatch_args

current_process_ -> int:
  #primitive.core.current_process_id

resource_freeing_module_ ::= get_generic_resource_group_

get_generic_resource_group_:
  #primitive.core.get_generic_resource_group
