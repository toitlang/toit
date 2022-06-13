// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bytes
import system.api.logging show LoggingService LoggingServiceClient
import encoding.base64

import .level

interface Target:
  log level/int message/string names/List? keys/List? values/List? trace/ByteArray? -> none

class DefaultTarget implements Target:
  log level/int message/string names/List? keys/List? values/List? trace/ByteArray? -> none:
    service_.log level message names keys values trace

/**
Logging service used by $DefaultTarget.
*/
service_/LoggingService ::= (LoggingServiceClient --no-open).open or
    StandardLoggingService_

/**
Standard logging service used when the system logging service cannot
  be resolved.
*/
class StandardLoggingService_ implements LoggingService:
  buffer_/bytes.Buffer ::= bytes.Buffer.with_initial_size 64

  log level/int message/string names/List? keys/List? values/List? trace/ByteArray? -> none:
    buffer ::= buffer_
    if names and names.size > 0:
      buffer.write "["
      names.size.repeat:
        if it > 0: buffer.write "."
        buffer.write names[it]
      buffer.write "] "

    buffer.write (level_name level)
    buffer.write ": "
    buffer.write message

    if keys and keys.size > 0:
      buffer.write " {"
      keys.size.repeat:
        if it > 0: buffer.write ", "
        buffer.write keys[it]
        buffer.write ": "
        buffer.write values[it]
      buffer.write "}"

    print buffer.to_string
    buffer.clear

    if trace:
      print_for_manually_decoding_ trace


print_for_manually_decoding_ message/ByteArray --from=0 --to=message.size:
  // Print a message on output to instruct how to easily decode.
  // The message is base64 encoded to limit the output size.
  print_ "----"
  print_ "Received a trace in the log. Executing the command below will"
  print_ "make it human readable:"
  print_ "----"
  // Block size must be a multiple of 3 for this to work, due to the 3/4 nature
  // of base64 encoding.
  BLOCK_SIZE := 1500
  for i := from; i < to; i += BLOCK_SIZE:
    end := i >= to - BLOCK_SIZE
    prefix := i == from ? "build/host/sdk/bin/toit.run tools/system_message.toit \"\$SNAPSHOT\" -b " : ""
    base64_text := base64.encode message[i..(end ? to : i + BLOCK_SIZE)]
    postfix := end ? "" : "\\"
    print_ "$prefix$base64_text$postfix"
