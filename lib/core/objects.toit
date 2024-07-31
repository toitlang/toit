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
    operator in sync with any `hash-code` method. That is, if a class
    has a `hash-code` member, then the equality and `hash-code`
    must agree. If two instances are equal (`a == b`), then their hash
    codes must also be equal (`a.hash-code == b.hash-code`).
  */
  operator == other:
    return identical this other

  /**
  Stringifies this object.

  # Inheritance
  Objects that need a human-friendly string representation should overwrite
    this method. The default string is based on the internal class-ID.
  */
  stringify -> string:
    return "an instance with class-id $(class-id this)"

  /**
  Looks up the class ID of the $object.
  */
  static class-id object -> int:
    #primitive.core.object-class-id

interface Interface_:

mixin Mixin_:

// A stub entry representing the internal Stack.
class Stack_:
  constructor: throw "Must not be instantiated"

/**
A Boolean value.
See also https://docs.toit.io/language/booleans.
*/
class bool:

/**
The class of `false`.
*/
class False extends bool:
  stringify:
    return "false"

/**
The class of `true`.
*/
class True extends bool:
  stringify:
    return "true"

class Box_:
  constructor .value_:
  value_ := ?

class Null_:
  stringify:
    return "null"

/**
A lambda, or closure.

Use this as a type for Lambdas (`:: ...`).

Lambdas are also known as closures in other languages.

Lambdas are executable pieces of code that can be passed around in a
  program and called for execution. A lambda can reference globals,
  fields, and variables.  Local variables can be captured.

# Aliases
- Closure

# Advanced
Lambdas and blocks both represent some code that can be called at a later point. This is
  why they look syntactically similar. However, contrary to blocks, lambdas can survive the
  function that created it. They can be returned, or stored in fields and globals.

When a lambda is called, the function that created it might not be alive anymore. As such,
  lambdas can not use non-local returns.

See also https://docs.toit.io/language/tasks.
*/
class Lambda:
  method_ ::= ?
  arguments_ ::= ?

  constructor.__ .method_ .arguments_:

  /**
  Calls this lambda with no arguments.
  */
  call:
    return __invoke-lambda__ 0

  /**
  Calls this lambda with one argument.
  */
  call a:
    return __invoke-lambda__ 1

  /**
  Calls this lambda with two argument.
  */
  call a b:
    return __invoke-lambda__ 2

  /**
  Calls this lambda with three arguments.
  */
  call a b c:
    return __invoke-lambda__ 3

  /**
  Calls this lambda with four arguments.
  */
  call a b c d:
    return __invoke-lambda__ 4

  /**
  See $super.
  */
  stringify:
    return "lambda"

  /**
  Returns the hash code of this lambda.
  */
  hash-code:
    return method_.hash-code

/**
Creates a new Lambda.

The $arguments are generally an array, except if the lambda only captures one
  argument. In that case, the captured value is passed directly.
*/
lambda__ method arguments/any arg-count -> Lambda:
  // If the arg-count is 1, then the arguments are not wrapped.
  // If the argument is not an array, then the interpreter knows that the
  //   lambda just captured a single value.
  // However, if it is an array, then the interpreter would not
  //   know whether the lambda captured the array, or the values in the array. As such
  //   we have to wrap the array in an array. This removes the ambiguity.
  if arg-count == 1 and arguments is Array_:
    arguments = create-array_ arguments
  return Lambda.__ method arguments

/**
The task that runs an initializer and all blocked tasks that are
  waiting for that task to finish.

Uses a tasks $Task_.next-blocked_ to maintain the list of blocked tasks.
*/
class LazyInitializerBlockedTasks_:
  initializing /Task_
  blocked-first /Task_ := ?
  blocked-last /Task_ := ?

  constructor .initializing first-blocked/Task_:
    blocked-first = first-blocked
    blocked-last = first-blocked

  add waiting/Task_:
    assert: blocked-last.next-blocked_ == null
    assert: waiting.next-blocked_ == null
    blocked-last.next-blocked_ = waiting
    blocked-last = waiting

  do-and-clear [block]:
    current /Task_? := blocked-first
    while current:
      next := current.next-blocked_
      current.next-blocked_ = null
      block.call current
      current = next

/**
Class to correctly initialize lazy statics.

The $id-or-tasks_ can be:
- the method ID that should be called to initialize the global
- the task that is currently running the initializer, or
- a $LazyInitializerBlockedTasks_ object that has the initializing task and all blocked tasks.
*/
class LazyInitializer_:
  id-or-tasks_ / any := ?

  constructor.__ .id-or-tasks_:

  call:
    assert: id-or-tasks_ is int
    // The __invoke_initializer__ builtin does a tail call to the method with the given id.
    return __invoke-initializer__ id-or-tasks_

  initializing -> Task_:
    if id-or-tasks_ is Task_: return id-or-tasks_
    return (id-or-tasks_ as LazyInitializerBlockedTasks_).initializing

  suspend-blocked blocked/Task_:
    if id-or-tasks_ is Task_:
      // First blocked task.
      id-or-tasks_ = LazyInitializerBlockedTasks_ id-or-tasks_ blocked
    else:
      // Add to the blocked queue.
      (id-or-tasks_ as LazyInitializerBlockedTasks_).add blocked

    // Suspend the task.
    next := blocked.suspend_
    task-transfer-to_ next false

  /**
  Resumes all blocked tasks and removes them from the linked list.
  */
  wake-blocked:
    if id-or-tasks_ is not LazyInitializerBlockedTasks_: return
    (id-or-tasks_ as LazyInitializerBlockedTasks_).do-and-clear: | blocked/Task_ |
      blocked.resume_

/**
Runs the $initializer function for the given $global.
*/
run-global-initializer__ global/int initializer/LazyInitializer_:
  this-task := Task_.current
  while true:
    if initializer.id-or-tasks_ is not int:
      // There is already an initialization in progress.
      initializing-task := initializer.initializing
      if initializing-task == this-task:
        // The initializer of the variable is trying to access the global
        // that is currently initialized.
        initialization-in-progress-failure_ global

      // Another task is already initializing this global.
      // Suspend us and mark us as waiting.
      initializer.suspend-blocked this-task

      // We have been woken up. This means that the previous initializer finished (successfully or not).
      new-value := __load-global-with-id__ global
      if new-value is not LazyInitializer_:
        return new-value
      // We still don't have a value. Either we have to try ourselves, or another task is already trying.
      // Start from the beginning of this function.
      initializer = new-value as LazyInitializer_
      continue

    // We are the first to initialize this global.
    // Replace the existing initializer with an initializer with our task. Other tasks may
    // add themselves to wait for us to finish.
    task-initializer := (LazyInitializer_.__ this-task)
    __store-global-with-id__ global task-initializer
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
      __store-global-with-id__ global result
      // Wake up all waiting tasks.
      task-initializer.wake-blocked
