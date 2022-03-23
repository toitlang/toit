// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Spawns a new process that starts executing the given lambda.
*/
spawn lambda/Lambda -> int:
  return hatch_primitive_ lambda.method_ lambda.arguments_

/**
Alias for $spawn.
*/
hatch_ lambda/Lambda:  // TODO(kasper): Mark as deprecated
  return spawn lambda

hatch_primitive_ method arguments:
  #primitive.core.hatch

// Entry point for process just being hatched.
__hatch_entry__:
  current := task
  current.initialize_entry_task_
  process_send_ -1 SYSTEM_SPAWNED_ null
  lambda := Lambda.__
    hatch_method_
    hatch_args_
  current.evaluate_ lambda

hatch_method_:
  #primitive.core.hatch_method

hatch_args_:
  #primitive.core.hatch_args

resource_freeing_module_ := get_generic_resource_group_

get_generic_resource_group_:
  #primitive.core.get_generic_resource_group

/// Only used by the system process, otherwise throws "NOT ALLOWED".
/// May also throw "NOT ALLOWED" if the process already terminated.
signal_kill_ id:
  if not signal_kill_primitive_ id: throw "NOT ALLOWED"

signal_kill_primitive_ id:
  #primitive.core.signal_kill
