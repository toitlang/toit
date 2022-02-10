// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..serialization show serialize deserialize

// Hatch a new process using this program heap and running the passed in lambda.
hatch_ lambda/Lambda:
  id := hatch_primitive_
    lambda.method_
    serialize lambda.arguments_
  return id

/// Only used by the system process, otherwise throws "NOT ALLOWED".
/// May also throw "NOT ALLOWED" if the process already terminated.
signal_kill_ id:
  if not signal_kill_primitive_ id: throw "NOT ALLOWED"

hatch_primitive_ method arguments:
  #primitive.core.hatch

// Entry point for process just being hatched.
__hatch_entry__:
  current := task
  current.initialize_entry_task_
  deserialized := deserialize hatch_args_
  // Turn deserialized lists into the more primitive array form.
  if deserialized is List: deserialized = Array_.from deserialized
  lambda := Lambda.__
    hatch_method_
    deserialized
  current.evaluate_ lambda

hatch_method_:
  #primitive.core.hatch_method

hatch_args_:
  #primitive.core.hatch_args

signal_kill_primitive_ id:
  #primitive.core.signal_kill

resource_freeing_module_ := get_generic_resource_group_

get_generic_resource_group_:
  #primitive.core.get_generic_resource_group
