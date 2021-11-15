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

class LazyInitializer_:
  constructor .id_:
  id_ / int ::= ?

  call:
    return __invoke_initializer__ id_

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

/**
Runs the $initializer function for the given $global.

The $initialization_in_progress_sentinel should be stored in the global while the
  initializer is run.
*/
run_global_initializer_ global/int initializer/LazyInitializer_ initialization_in_progress_sentinel:
  if initializer == initialization_in_progress_sentinel:
    initialization_in_progress_failure_ global

  __store_global_with_id__ global initialization_in_progress_sentinel

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
