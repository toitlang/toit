// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Prints the $message.

/* TODO(florian): the following sentence will probably get stale soon. */
The resulting message is stringified using $Object.stringify.
*/
print message/any:
  print_ message

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

/**
Dumps the an empty new line on stdout and flushes it.

Does not yield the currently running task.
*/
print_:
  print_ ""

/**
Dumps the string of $object and a newline on stdout and flushes it.

Does not yield the currently running task.
*/
print_ object:
  write_string_on_stdout_ object.stringify true

/**
Dumps the string $message and a newline on stdout and flushes it.

Does not yield the currently running task.
*/
print_string_on_stdout_ message:
  write_string_on_stdout_ message true

/**
Dumps the string of $object on stdout and flushes it.
If $add_newline is true adds a "\n" to the output.

Does not yield the currently running task.
*/
write_on_stdout_ object add_newline:
  write_string_on_stdout_ object.stringify add_newline

/**
Dumps the string $message on stdout and flushes it.
If $add_newline is true adds a "\n" to the output.

Does not yield the currently running task.
*/
write_string_on_stdout_ message add_newline:
  #primitive.core.write_string_on_stdout

/**
Dumps the string of $object and a newline on stderr and flushes it.

Does not yield the currently running task.
*/
print_on_stderr_ object:
  write_string_on_stderr_ object.stringify true

/**
Dumps the string $message and a newline on stderr and flushes it.

Does not yield the currently running task.
*/
print_string_on_stderr_ message:
  write_string_on_stderr_ message true

/**
Dumps the string of $object on stderr and flushes it.
If $add_newline is true adds a "\n" to the output.

Does not yield the currently running task.
*/
write_on_stderr_ object add_newline:
  write_string_on_stderr_ object.stringify add_newline

/**
Dumps the string $message on stderr and flushes it.
If $add_newline is true adds a "\n" to the output.

Does not yield the currently running task.
*/
write_string_on_stderr_ message add_newline:
  #primitive.core.write_string_on_stderr
