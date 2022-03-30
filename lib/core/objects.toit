// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Base classes for the objects in the Toit language.
*/

/**
A base class for all classes.

All classes implicitly extend this class.
*/
class Object:
  /**
  Whether this object is equal to the $other.

  By default, $identical is used for equality.

  # Inheritance
  Classes overwrite this operator to get an equality specific to their needs.
    Equality operators often compare the type and field contents. For example:
  ```
  class Pin:
    number/int

    constructor .number:

    operator == other:
      if other is not Pin: return false
      return number == other.number
  ```
  A class doesn't have to follow the above format, but it must keep the
    operator in sync with any `hash_code` method. That is, if a class
    has a `hash_code` member, then the equality and `hash_code`
    must agree. If two instances are equal (`a == b`), then their hash
    codes must also be equal (`a.hash_code == b.hash_code`).
  */
  operator == other:
    #primitive.core.object_equals

  /**
  Stringifies this object.

  # Inheritance
  Objects that need a human-friendly string representation should overwrite
    this method. The default string is based on the internal class-ID.
  */
  stringify -> string:
    return "an instance with class-id $(class_id this)"

  /**
  Looks up the class ID of the $object.
  */
  static class_id object -> int:
    #primitive.core.object_class_id

// For simplicity add the Object properties to the base interface class.
// This way, the type-checker doesn't complain when we use them on interface types.
interface Interface_:
  operator == other
  stringify -> string

// A stub entry for the Meta class which is the class of classes themselves.
class Class_:
  constructor: throw "Must not be instantiated"

// A stub entry representing the internal Stack.
class Stack_:
  constructor: throw "Must not be instantiated"

/**
A Boolean value.
*/
class bool:

class False_ extends bool:
  stringify:
    return "false"


class True_ extends bool:
  stringify:
    return "true"

class Box_:
  constructor .value_:
  value_ := ?

class Null_:
  stringify:
    return "null"

/**
A lambda.

Use this as a type for Lambdas (`:: ...`).

Lambdas are also known as closures in other languages.

Lambdas are executable pieces of code that can be passed around in a
  program and called for execution. A lambda can reference globals,
  fields, and variables.

# Aliases
- Closure

# Advanced
Lambdas and blocks both represent some code that can be called at a later point. This is
  why they look syntactically similar. However, contrary to blocks, lambdas can survive the
  function that created it. They can be returned, or stored in fields and globals.

When a lambda is called, the function that created it might not be alive anymore. As such,
  lambdas can not use non-local returns.
*/
class Lambda:
  method_ ::= ?
  arguments_ ::= ?

  constructor.__ .method_ .arguments_:

  /**
  Calls this lambda with no arguments.
  */
  call:
    return __invoke_lambda__ 0

  /**
  Calls this lambda with one argument.
  */
  call a:
    return __invoke_lambda__ 1

  /**
  Calls this lambda with two argument.
  */
  call a b:
    return __invoke_lambda__ 2

  /**
  Calls this lambda with three arguments.
  */
  call a b c:
    return __invoke_lambda__ 3

  /**
  Calls this lambda with four arguments.
  */
  call a b c d:
    return __invoke_lambda__ 4

  /**
  See $super.
  */
  stringify:
    return "lambda"

  /**
  Returns the hash code of this lambda.
  */
  hash_code:
    return method_.hash_code

/**
Creates a new Lambda.

The $arguments are generally an array, except if the lambda only captures one
  argument. In that case, the captured value is passed directly.
*/
lambda_ method arguments/any arg_count -> Lambda:
  // If the arg-count is 1, then the arguments are not wrapped.
  // If the argument is not an array, then the interpreter knows that the
  //   lambda just captured a single value.
  // However, if it is an array, then the interpreter would not
  //   know whether the lambda captured the array, or the values in the array. As such
  //   we have to wrap the array in an array. This removes the ambiguity.
  if arg_count == 1 and arguments is Array_:
    arguments = create_array_ arguments
  return Lambda.__ method arguments

class LazyInitializer_:
  constructor .id_or_task_:
  id_or_task_ / any := ?

  call:
    assert: id_or_task_ is int
    // The __invoke_initializer__ builtin does a tail call to the method with the given id.
    return __invoke_initializer__ id_or_task_

  initializing -> Task_:
    if id_or_task_ is Task_: return id_or_task_
    if id_or_task_ is InitializingTask_: return (id_or_task_ as InitializingTask_).task
    throw "BAD_LAZY_INITIALIZER_CALL"

  add_waiting task/Task_:
    if id_or_task_ is Task_: id_or_task_ = InitializingTask_ id_or_task_
    if not id_or_task_ is InitializingTask_: throw "BAD_LAZY_INITIALIZER_CALL"
    (id_or_task_ as InitializingTask_).add_waiting task

  do_waiting [block]:
    if id_or_task_ is Task_: return
    if not id_or_task_ is InitializingTask_: throw "BAD_LAZY_INITIALIZER_CALL"
    current := (id_or_task_ as InitializingTask_).waiting
    while current:
      block.call current.task
      current = current.next


class InitializingTask_:
  task / Task_
  waiting / WaitingTask_? := null
  last_waiting / WaitingTask_? := null

  constructor .task:

  add_waiting task/Task_:
    new_last := WaitingTask_ task
    if not waiting:
      waiting = new_last
      last_waiting = waiting
    else:
      last_waiting.next = new_last
      last_waiting = new_last

class WaitingTask_:
  task /Task_
  next /WaitingTask_? := null
  constructor .task:

/**
Runs the $initializer function for the given $global.
*/
run_global_initializer_ global/int initializer/LazyInitializer_:
  while true:
    if initializer.id_or_task_ is not int:
      // There is already an initialization in progress.
      initializing_task := initializer.initializing
      this_task := task
      if initializing_task == this_task:
        // The initializer of the variable is trying to access the global
        // that is currently initialized.
        initialization_in_progress_failure_ global

      // Another task is already initializing this global.
      // Mark us as waiting.
      initializer.add_waiting this_task
      next := this_task.suspend_
      task_yield_to_ next

      // We have been woken up. This means that the previous initializer finished (successfully or not).
      new_value := __load_global_with_id__ global
      if new_value is not LazyInitializer_:
        return new_value
      // We still don't have a value. Either we have to try ourselves, or another task is already trying.
      // Start from the beginning of this function.
      initializer = new_value as LazyInitializer_
      continue

    // We are the first to initialize this global.
    // Replace the existing initializer with an initializer with our task. Other tasks may
    // add themselves to wait for us to finish.
    task_initializer := (LazyInitializer_ task)
    __store_global_with_id__ global task_initializer
    // If the initializer fails, we store the original initializer back in
    // the global. This means that it is possible to invoke a global that throws
    // again.
    result / any := initializer
    try:
      result = initializer.call
      return result
    finally:
      // Either store the computed result, if the initializer succeeded, or
      // store the original initializer if it failed.
      __store_global_with_id__ global result
      // Wake up all waiting tasks.
      task_initializer.do_waiting:
        (it as Task_).resume_
