// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// This is the system entry point. It is responsible for
// calling the main function and halting the system after
// it returns.
__entry__main task -> none:
  // First we set the current task variable. We must do this early,
  // because other parts of the core library code might rely on it.
  // As an example, accessing a lazily initialized global variable
  // requires access to the task.
  Task_.current = task
  task.initialize_entry_task_
  task.evaluate_:
    #primitive.intrinsics.main main_arguments_

// This is the entry point for processes just being spawned.
// It calls the lambda passed in the spawn arguments.
__entry__spawn task -> none:
  // First we set the current task variable. We must do this early,
  // because other parts of the core library code might rely on it.
  // As an example, accessing a lazily initialized global variable
  // requires access to the task.
  Task_.current = task
  task.initialize_entry_task_
  lambda := Lambda.__ spawn_method_ spawn_arguments_
  task.evaluate_: lambda.call

// This is the entry point for newly created tasks.
__entry__task lambda -> none:
  // The entry stack setup is a bit complicated, so when we
  // transfer to a task stack for the first time, the
  // `task transfer` primitive will provide the current task
  // for us on the stack. The `null` assigned to `task` below
  // is skipped and we let the value passed to us take its place.
  task := null
  assert: identical task Task_.current
  task.evaluate_: lambda.call

// --------------------------------------------------------

/**
Returns the name of the toit file, image, or snapshot that the
  current program was run from.  May return null if this information
  is not available.
*/
program_name -> string?:
  #primitive.core.command

main_arguments_ -> any:
  #primitive.core.main_arguments

spawn_method_ -> int:
  #primitive.core.spawn_method

spawn_arguments_ -> any:
  #primitive.core.spawn_arguments
