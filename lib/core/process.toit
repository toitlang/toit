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
  pid := process_spawn_ lambda.method_ lambda.arguments_
  process := Process_ pid
  if priority: process.priority = priority
  return process

/**
...
*/
interface Process:
  static current ::= Process_ process_current_id_

  /**
  ...
  */
  id -> int

  /**
  ...
  */
  priority -> int

  /**
  ...
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

process_spawn_ method arguments -> int:
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
