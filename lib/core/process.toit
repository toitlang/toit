// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Spawns a new process that starts executing the given lambda.
The new process does not share any memory with the spawning process. If the lambda
  captures variables, those are copied to the new process.
May throw if the captured variables can't be serialized.
*/
spawn lambda/Lambda --priority/int?=null -> Process:
  priority = priority or -1
  pid := process_spawn_ priority lambda.method_ lambda.arguments_
  return Process_ pid

interface Process:
  static PRIORITY_IDLE     /int ::= 0
  static PRIORITY_LOW      /int ::= 43
  static PRIORITY_NORMAL   /int ::= 128
  static PRIORITY_HIGH     /int ::= 213
  static PRIORITY_CRITICAL /int ::= 255

  /**
  The current process.
  */
  static current ::= Process_ process_current_id_

  /**
  Returns the unique id of the process.
  */
  id -> int

  /**
  Returns the priority of the process.

  The priority is between 0 and 255 and a high priority means
    that the process is more likely to be scheduled and less
    likely to be interrupted.

  Throws an exception if the process no longer lives.
  */
  priority -> int

  /**
  Updates the priority of the process.

  The $priority must be between 0 and 255 and a high priority
    means that the process is more likely to be scheduled and
    less likely to be interrupted.

  Throws an exception if the process no longer lives.
  */
  priority= priority/int -> none

// --------------------------------------------------------------------------

class Process_ implements Process:
  id/int
  constructor .id:

  priority -> int:
    return process_get_priority_ id
  priority= priority/int -> none:
    process_set_priority_ id priority

process_spawn_ priority method arguments -> int:
  #primitive.core.spawn

process_current_id_ -> int:
  #primitive.core.process_current_id

process_get_priority_ pid/int -> int:
  #primitive.core.process_get_priority

process_set_priority_ pid/int priority/int -> none:
  #primitive.core.process_set_priority

// --------------------------------------------------------------------------

resource_freeing_module_ ::= get_generic_resource_group_

get_generic_resource_group_:
  #primitive.core.get_generic_resource_group
