// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import rpc
import rpc.proto.rpc.rpc_pb

/**
Prints the $message.

/* TODO(florian): the following sentence will probably get stale soon. */
The resulting message is stringified using $Object.stringify.
*/
print message/any:
  print_ message
  message = message.stringify
  if not is_root_process:
    print_request := rpc_pb.PrintRequest
    print_request.message = message
    request := rpc_pb.Request
    request.request_print = print_request
    rpc.invoke request

/**
Prints an empty line.

This function is generally used to improve the output of the console output, but may
  have no effect on other receivers of the print message.
*/
print:
  print ""

/**
Prints the given $object for debugging.

Does not yield the currently running task.
*/
debug object:
  print_ object

/**
Prints an empty line for debugging.

Does not yield the currently running task.
*/
debug:
  print_

// Dumps an empty line on stdout.
print_:
  print_ ""

// Dumps print string of $object on stdout.
print_ object:
  print_string_on_stdout_ object.stringify

// Dumps the string $message on stdout and flushes.
print_string_on_stdout_ message:
  #primitive.core.print_string_on_stdout

// Dumps the string of $object on stderr.
print_on_stderr_ object:
  print_string_on_stderr_ object.stringify

// Dumps the string $message on stderr and flushes.
print_string_on_stderr_ message:
  #primitive.core.print_string_on_stderr
