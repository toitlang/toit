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
  pid := process-spawn_ priority lambda.method_ lambda.arguments_
  return Process_ pid

interface Process:
  static PRIORITY-IDLE     /int ::= 0
  static PRIORITY-LOW      /int ::= 43
  static PRIORITY-NORMAL   /int ::= 128
  static PRIORITY-HIGH     /int ::= 213
  static PRIORITY-CRITICAL /int ::= 255

  /**
  The current process.
  */
  static current ::= Process_ process-current-id_

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
    return process-get-priority_ id
  priority= priority/int -> none:
    process-set-priority_ id priority

process-spawn_ priority method arguments -> int:
  #primitive.core.spawn

process-current-id_ -> int:
  #primitive.core.process-current-id

process-get-priority_ pid/int -> int:
  #primitive.core.process-get-priority

process-set-priority_ pid/int priority/int -> none:
  #primitive.core.process-set-priority

// --------------------------------------------------------------------------

resource-freeing-module_ ::= get-generic-resource-group_

get-generic-resource-group_:
  #primitive.core.get-generic-resource-group
