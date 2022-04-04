// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/** Exception throwing and handling. */

/**
Assertion failed error.

Thrown when an assertion fails both by the 'assert:' language construct
  and by other assertion checking libraries.
*/
ASSERTION_FAILED_ERROR ::= "ASSERTION_FAILED"

/**
Cancelled error.

Thrown when a $task has been cancelled.
*/
CANCELED_ERROR ::= "CANCELED"
/**
Deadline exceeded error.

Thrown when a $with_timeout times out.
*/
DEADLINE_EXCEEDED_ERROR ::= "DEADLINE_EXCEEDED"


/**
Throws the given $exception.

Unwinds the stack of this task calling associated finally-blocks. By default,
  a task with an exception will print the stack trace and terminate the
  task.
The exception can also be caught with a $(catch [block]).
*/
throw exception/any -> none:
  trace ::= encode_error_ "EXCEPTION" "$exception"
  __throw__ (Exception_ exception trace)

/**
Rethrows the given $exception along with the $trace.

Works like $throw except it uses the given $trace rather than generating one
  at the throw point.

Used to rethrow a caught exception (see $(catch [--trace] [block])) as though
  it wasn't caught.
*/
rethrow exception/any trace/ByteArray? -> none:
  __throw__ (Exception_ exception trace)

/**
Marks code point as unreachable.

Must not be reached in the program.
*/
unreachable -> none:
  throw "Unreachable"

/**
Variant of $(catch [--trace] [--unwind] [block]).

If an exception is thrown during the $block call, then the trace is printed
  if the $trace is true (and the trace can otherwise be printed).

If an exception is thrown during the $block call, then unwinding continues if
  the $unwind is true.
*/
catch --trace/bool=false --unwind/bool=false [block]:
  return catch
    --trace=: trace
    --unwind=: unwind
    block

/**
Variant of $(catch [--trace] [--unwind] [block]).

If an exception is thrown during the $block call, then the trace is printed
  if the $trace is true (and the trace can otherwise be printed).
*/
catch --trace/bool=false [--unwind] [block]:
  return catch
    --trace=: trace
    --unwind=unwind
    block

/**
Variant of $(catch [--trace] [--unwind] [block]).

If an exception is thrown during the $block call, then unwinding continues if
  the $unwind is true.
*/
catch [--trace] --unwind/bool=false [block]:
  return catch
    --trace=trace
    --unwind=: unwind
    block

/**
Catches exceptions thrown in the given $block.

Returns null if the call to the $block completes without exception.

Returns the thrown exception if an exception is thrown during the call of the
  $block and $unwind returns a falsy value (see below).

The $trace block decides whether the trace should be printed in case an
  exception has been thrown. The $trace block is called with the thrown
  exception and the trace (`trace.call exception trace`) and should return
  a boolean. If the $trace call returns true, then the trace is
  printed. However, the trace can only be printed if there is a trace and
  this task hasn't been cancelled.

The $unwind block decides whether unwinding should continue in case of a
  caught exception. The $unwind block is called with the thrown exception and
  the trace (`unwind.call exception trace`) and should return a boolean
  value. If $unwind call returns true, then unwinding continues.
*/
catch [--trace] [--unwind] [block]:
  try:
    block.call
    return null
  finally: | is_exception exception |
    if is_exception:
      stack ::= exception.trace
      value ::= exception.value
      // If the task is unwinding due to cancelation, don't catch the exception and
      // don't print a stack trace; just unwind.
      is_canceled_unwind := value == CANCELED_ERROR and task.is_canceled
      if not is_canceled_unwind:
        if stack and trace.call value stack:
          exception.trace = null  // Avoid reporting the same stack trace multiple times.
          system_send_ SYSTEM_MIRROR_MESSAGE_ stack
          // We check messages here in case there is no system process.  This allows
          // the stack trace to be discovered in the message queue and printed out,
          // since no system process is going to handle it.
          process_messages_
        if not unwind.call value stack: return value

// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------

// TODO(kasper): Instances of this class are exposed as arguments to finally
// blocks. We should probably make this public and turn it into something
// useful, but it might make sense to look into exception/error hierarchies
// first.
class Exception_:
  value/any ::= ?
  trace/ByteArray? := ?
  constructor .value .trace:

// Spontaneous entry points invoked by the interpreter when failure occurs at runtime.
// stack_trace is passed to avoid extra frame in trace.
allocation_failure_ class_id:
  rethrow "ALLOCATION_FAILED"
    encode_error_ "ALLOCATION_FAILED" class_id

lookup_failure_ receiver selector_or_selector_offset:
  rethrow "LOOKUP_FAILED"
    encode_error_ "LOOKUP_FAILED"
      create_array_ selector_or_selector_offset  (Object.class_id receiver) receiver

uninitialized_global_failure_ global_id:
  rethrow "UNINITIALIZED_GLOBAL"
    encode_error_ "UNINITIALIZED_GLOBAL" global_id

initialization_in_progress_failure_ global_id:
  rethrow "INITIALIZATION_IN_PROGRESS"
    encode_error_ "INITIALIZATION_IN_PROGRESS" global_id

program_failure_ bci:
  rethrow "INVALID_PROGRAM"
    encode_error_ "INVALID_PROGRAM" bci

/**
Signals an 'as' failure.
$id might be either:
- a class name of type $string
- an absolute BCI of the 'as' check.
*/
as_check_failure_ receiver id:
  rethrow "AS_CHECK_FAILED"
    encode_error_ "AS_CHECK_FAILED"
      create_array_ receiver id

primitive_lookup_failure_ module index:
  rethrow "PRIMITIVE_LOOKUP_FAILED"
    encode_error_ "PRIMITIVE_LOOKUP_FAILED" "Failed to find primitive $module:$index"

too_few_code_arguments_failure_ is_block expected provided bci:
  rethrow "CODE_INVOCATION_FAILED"
    encode_error_ "CODE_INVOCATION_FAILED"
        create_array_ is_block expected provided bci
