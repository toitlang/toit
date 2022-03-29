// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.api.print show PrintService PrintServiceClient

/**
Prints the $message.

/* TODO(florian): the following sentence will probably get stale soon. */
The resulting message is stringified using $Object.stringify.
*/
print message/any:
  service_.print message.stringify

/**
Prints an empty line.

This function is generally used to improve the output of the console output, but may
  have no effect on other receivers of the print message.
*/
print:
  service_.print ""

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
  write_on_stdout_ object.stringify true

/**
Dumps the string $message on stdout and flushes it.
If $add_newline is true adds a "\n" to the output.

Does not yield the currently running task.
*/
write_on_stdout_ message/string add_newline/bool -> none:
  #primitive.core.write_string_on_stdout

/**
Dumps the string of $object and a newline on stderr and flushes it.

Does not yield the currently running task.
*/
print_on_stderr_ object:
  write_on_stderr_ object.stringify true

/**
Dumps the string $message on stderr and flushes it.
If $add_newline is true adds a "\n" to the output.

Does not yield the currently running task.
*/
write_on_stderr_ message/string add_newline/bool -> none:
  #primitive.core.write_string_on_stderr

/**
Print service used by $print.
*/
service_/PrintService ::= (PrintServiceClient --no-open).open or
    (StandardPrintService_)

/**
Standard print service used when the system print service cannot
  be resolved.
*/
class StandardPrintService_ implements PrintService:
  print message/string -> none:
    write_on_stdout_ message true
