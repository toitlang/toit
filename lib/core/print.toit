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

// Dumps an empty line on stdout.
print_:
  print_ ""

// Dumps print string of $object on stdout.
print_ object:
  print_string_on_stdout_ object.stringify

// Dumps the string $message on stdout and flushes.
print_string_on_stdout_ message:
  write_string_on_stdout_ message
  write_string_on_stdout_ "\n"

// Dumps the string $message on stdout without a newline and flushes.
write_on_stdout_ message:
  write_string_on_stdout_ message.stringify

// Dumps the string $message on stdout without a newline and flushes.
write_string_on_stdout_ message:
  #primitive.core.write_string_on_stdout

// Dumps the string of $object on stderr.
print_on_stderr_ object:
  print_string_on_stderr_ object.stringify

// Dumps the string $message on stderr and flushes.
print_string_on_stderr_ message:
  write_string_on_stderr_ message
  write_string_on_stderr_ "\n"

// Dumps the string of $object on stderr without adding a newline and flushes.
write_on_stderr_ object:
  write_string_on_stderr_ object.stringify

// Dumps the string $message on stderr without adding a newline and flushes.
write_string_on_stderr_ message:
  #primitive.core.write_string_on_stderr
