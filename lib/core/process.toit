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
  return spawn_ lambda.method_ lambda.arguments_

/**
...
*/
class Process:
  /**
  ...
  */
  static id -> int:
    #primitive.core.process_current_id

  /**
  ...
  */
  static priority -> int:
    return get_priority_ id

  /**
  ...
  */
  priority= priority/int -> none:
    set_priority_ id priority

// --------------------------------------------------------------------------

spawn_ method arguments:
  #primitive.core.spawn

get_priority_ pid/int -> int:
  #primitive.core.process_get_priority

set_priority_ pid/int priority/int -> none:
  #primitive.core.process_set_priority

resource_freeing_module_ ::= get_generic_resource_group_

get_generic_resource_group_:
  #primitive.core.get_generic_resource_group
